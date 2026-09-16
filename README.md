# MRX Notetaker

Records calls locally so they can be transcribed and summarised even when the meeting organiser has
disabled Teams transcription. No bot joins the meeting. Two tracks per call: microphone (you) and
system audio (everyone else). Recordings go to a OneDrive folder; transcription happens on a
separate server, not in this repo.

- `mac/` Swift app for macOS 14.2+ (Core Audio process tap, no virtual audio driver, no Screen Recording permission). Built and ad-hoc signed by GitHub Actions.
- `install.sh` one-line installer: `curl -fsSL https://raw.githubusercontent.com/ikourkouta-svg/mrx-notetaker/main/install.sh | bash -s -- you@company.com`
- `linux/` Python recorder for PipeWire/PulseAudio plus a systemd user unit.

Session folder contract: `mic.*`, `system.*`, then `session.json` written last
(`user`, `host`, `source`, `version`, `selftest`, `started`, `ended` in UTC, and on macOS `files` = name to byte size).

Recording other people requires telling them. Say at the start of the call that you are taking notes with a recorder.
