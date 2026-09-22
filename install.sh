#!/bin/bash
# MRX Notetaker installer for macOS 14.2 or newer. Safe to run again (it updates and re-tests).
#   curl -fsSL https://raw.githubusercontent.com/ikourkouta-svg/mrx-notetaker/main/install.sh | bash -s -- you@company.com
set -euo pipefail
EMAIL="${1:?Add your email address at the end of the command}"
COPILOT_TOKEN="${2:-}"   # optional: turns on the live copilot
ENDPOINT="https://mrx-advice.vercel.app/api/advice"
SUPPORT="$HOME/Library/Application Support/MRXNotetaker"
REPO="ikourkouta-svg/mrx-notetaker"
APP="$HOME/Applications/MRXNotetaker.app"
AGENT="$HOME/Library/LaunchAgents/com.mrx.notetaker.plist"
LOG="$HOME/Library/Logs/MRXNotetaker.log"

IFS=. read -r major minor _ <<< "$(sw_vers -productVersion).0"
if (( major < 14 || (major == 14 && minor < 2) )); then
  echo "STOP: this Mac runs macOS $(sw_vers -productVersion). Update macOS to 14.2 or newer, then run the command again."
  exit 1
fi
# OneDrive puts the shared folder in different places depending on its version, so look everywhere.
# Not finding it no longer stops the install: recordings wait on the Mac and upload once it appears.
FOUND=$(find "$HOME/Library/CloudStorage" "$HOME" -maxdepth 3 -type d -iname "MRX-Notetaker" 2>/dev/null \
        | grep -i onedrive | head -1 || true)
if [[ -n "$FOUND" ]]; then
  echo "OneDrive folder found: $FOUND"
else
  echo "NOTE: MRX-Notetaker is not visible yet. Installing anyway; recordings wait on this Mac and upload later."
  echo "---- please send John a photo of the lines below ----"
  ls -d "$HOME"/Library/CloudStorage/* "$HOME"/OneDrive* 2>/dev/null || echo "(no OneDrive folders at all)"
  for d in "$HOME"/Library/CloudStorage/OneDrive* "$HOME"/OneDrive*; do
    [[ -d "$d" ]] && { echo "inside $d:"; ls "$d" 2>/dev/null | head -15; }
  done
  echo "-----------------------------------------------------"
fi

echo "Downloading MRX Notetaker..."
launchctl bootout "gui/$(id -u)/com.mrx.notetaker" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
curl -fsSL "https://github.com/$REPO/releases/latest/download/MRXNotetaker.zip" -o /tmp/MRXNotetaker.zip
rm -rf "$APP"
ditto -x -k /tmp/MRXNotetaker.zip "$HOME/Applications"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

if [[ -n "$COPILOT_TOKEN" ]]; then
  mkdir -p "$SUPPORT"
  printf '{"endpoint":"%s","token":"%s"}\n' "$ENDPOINT" "$COPILOT_TOKEN" > "$SUPPORT/copilot.json"
  if [[ ! -s "$SUPPORT/whisper-model.bin" ]]; then
    # medium understands Greek noticeably better; Intel Macs get the small model so it stays usable
    if [[ "$(uname -m)" == "arm64" ]]; then MODEL=ggml-medium.bin; else MODEL=ggml-small.bin; fi
    echo "Downloading the speech model once ($MODEL, this can take a few minutes)..."
    curl -fL --progress-bar "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL" -o "$SUPPORT/whisper-model.bin"
  fi
  echo "Live copilot enabled."
fi

while true; do
  echo
  echo "TEST: for the next 10 seconds play any YouTube video with sound AND say a few words."
  echo "If the Mac asks to allow the microphone or audio recording, click Allow."
  : > /tmp/MRXNotetaker-test.log
  open -W --stdout /tmp/MRXNotetaker-test.log --stderr /tmp/MRXNotetaker-test.log "$APP" --args --user "$EMAIL" --selftest
  cat /tmp/MRXNotetaker-test.log
  echo
  read -r -p "Did the Mac ask you anything during this test? Type y to run the test again, or press Enter to finish: " again < /dev/tty
  [[ "$again" == y* ]] || break
done

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.mrx.notetaker</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/MRXNotetaker</string><string>--user</string><string>$EMAIL</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo
echo "DONE. MRX Notetaker now starts by itself with the Mac and records Teams and Zoom calls automatically."
echo "Look at the top right of your screen, next to the clock: MRX (grey) = waiting, REC (red) = recording a call."
