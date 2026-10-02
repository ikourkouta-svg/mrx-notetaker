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
# Only OneDrive roots: scanning all of $HOME would make macOS ask about Documents, Desktop and Downloads.
FOUND=$(find "$HOME"/Library/CloudStorage/OneDrive* "$HOME"/OneDrive* -maxdepth 2 -type d -iname "MRX-Notetaker" \
        2>/dev/null | head -1 || true)
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
  # The copilot only transcribes when advice is asked for, and has to answer in seconds, so it runs
  # a light model. The real transcript, where Greek accuracy matters, is made on Doom with large-v3.
  # medium was here until 1 Oct 2026 and kept a MacBook hot for the whole call.
  if [[ "$(uname -m)" == "arm64" ]]; then MODEL=ggml-small.bin; else MODEL=ggml-base.bin; fi
  if [[ ! -s "$SUPPORT/whisper-model.bin" ]] || [[ "$(cat "$SUPPORT/whisper-model.name" 2>/dev/null)" != "$MODEL" ]]; then
    echo "Downloading the speech model once ($MODEL, this can take a few minutes)..."
    curl -fL --progress-bar "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL" -o "$SUPPORT/whisper-model.bin"
    echo "$MODEL" > "$SUPPORT/whisper-model.name"
  fi
  echo "Live copilot enabled."
fi

# No sync folder on this Mac means finished recordings have nowhere to go: Costas' MacBook held
# 12 of them from 16 Sep to 2 Oct 2026 and only a local log said so. One sign-in and the app
# uploads them straight to the shared folder over https instead.
if [[ -z "${FOUND:-}" ]] && ! grep -q refresh_token "$SUPPORT/graph.json" 2>/dev/null; then
  echo
  echo "This Mac cannot see the shared OneDrive folder, so recordings will be uploaded directly."
  echo "That needs one sign-in with your work account. Follow the two lines below."
  "$APP/Contents/MacOS/MRXNotetaker" --user "$EMAIL" --login \
    || echo "WARNING: sign-in did not finish. Recordings will wait on this Mac. Run the installer again."
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

# Diagnostics go to the shared OneDrive folder so John can read them without screenshots.
FOUND=${FOUND:-$(find "$HOME"/Library/CloudStorage/OneDrive* "$HOME"/OneDrive* -maxdepth 2 -type d -iname "MRX-Notetaker" 2>/dev/null | head -1)}
if [[ -n "$FOUND" ]]; then
  sleep 8
  DIAG="$FOUND/_diagnostics/$(date -u +%Y%m%d-%H%M%S)"
  mkdir -p "$DIAG"
  { sw_vers; uname -m; echo; launchctl print "gui/$(id -u)/com.mrx.notetaker" 2>&1 | head -40; } > "$DIAG/system.txt"
  cp /tmp/MRXNotetaker-test.log "$DIAG/selftest.log" 2>/dev/null || true
  tail -200 "$LOG" > "$DIAG/app.log" 2>/dev/null || true
  ls -t "$HOME"/Library/Logs/DiagnosticReports/MRXNotetaker* 2>/dev/null | head -3 | while read -r f; do cp "$f" "$DIAG/"; done
  echo "Diagnostics sent to John."
fi
echo
echo "DONE. MRX Notetaker now starts by itself with the Mac and records Teams and Zoom calls automatically."
echo "Look at the top right of your screen, next to the clock: MRX (grey) = waiting, REC (red) = recording a call."
if [[ -z "${FOUND:-}" ]]; then
  echo "This Mac uploads over https because the shared OneDrive folder is not synced here."
  echo "If you ever see recordings piling up, send John: tail -5 ~/Library/Logs/MRXNotetaker.log"
fi
