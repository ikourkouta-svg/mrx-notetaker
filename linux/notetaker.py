#!/usr/bin/env python3
"""Automatic call recorder for Linux (PipeWire/PulseAudio).

Starts when a meeting app (Teams, Chrome, Zoom...) opens the microphone and stops 45 s after it
releases it. Writes two tracks, mic (you) and system (everyone else), then session.json LAST
into OUTBOX/<user>_<timestamp>/, where the transcription job picks it up.

Usage: notetaker.py --user john@mrexporttoafrica.com [--outbox DIR] [--selftest]
"""
import argparse
import datetime as dt
import json
import shutil
import signal
import socket
import subprocess
import time
from pathlib import Path

# Doom is John's own machine and its summaries reach John alone, so personal call apps are included
# here. The macOS build deliberately leaves them out: Costas was told they are never recorded.
MEETING_APPS = ("teams-for-linux", "teams", "chrome", "chromium", "msedge", "microsoft-edge", "firefox",
                "zoom", "viber", "whatsapp", "telegram", "signal-desktop", "skype")
POLL, GRACE = 3, 45


def meeting_app_on_mic():
    out = subprocess.run(["pactl", "-f", "json", "list", "source-outputs"], capture_output=True, text=True).stdout
    for o in json.loads(out or "[]"):
        binary = (o["properties"].get("application.process.binary") or "").lower()
        if binary.startswith(MEETING_APPS):
            return binary
    return None


def ffmpeg(source, dest):
    return subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "pulse", "-i", source,
                             "-ac", "1", "-c:a", "libopus", "-b:a", "32k", str(dest)], stdin=subprocess.DEVNULL)


def record(user, outbox, stop_when, selftest=False):
    started = dt.datetime.now(dt.timezone.utc)
    name = f"{user.split('@')[0]}_{'selftest_' if selftest else ''}{started:%Y%m%d-%H%M%S}"
    work = outbox.parent / "recording" / name
    work.mkdir(parents=True, exist_ok=True)
    sink = subprocess.run(["pactl", "get-default-sink"], capture_output=True, text=True).stdout.strip()
    procs = [ffmpeg("@DEFAULT_SOURCE@", work / "mic.ogg"), ffmpeg(f"{sink}.monitor", work / "system.ogg")]
    print(f"recording {name}", flush=True)
    stop_when()
    for p in procs:
        p.send_signal(signal.SIGINT)  # lets ffmpeg finalise the file
    for p in procs:
        p.wait(timeout=30)
    ended = dt.datetime.now(dt.timezone.utc)
    (work / "session.json").write_text(json.dumps({
        "user": user, "host": socket.gethostname(), "source": "linux", "version": 1, "selftest": selftest,
        "started": started.isoformat().replace("+00:00", "Z"), "ended": ended.isoformat().replace("+00:00", "Z")}))
    shutil.move(str(work), outbox / name)
    print(f"saved {outbox / name} ({(ended - started).seconds // 60} min)", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", required=True)
    ap.add_argument("--outbox", default=str(Path.home() / "MeetingRecordings/outbox"))
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    outbox = Path(args.outbox)
    outbox.mkdir(parents=True, exist_ok=True)
    if args.selftest:
        return record(args.user, outbox, lambda: time.sleep(10), selftest=True)

    def until_call_ends():
        last_seen = time.time()
        while time.time() - last_seen < GRACE:
            time.sleep(POLL)
            if meeting_app_on_mic():
                last_seen = time.time()

    while True:
        app = meeting_app_on_mic()
        if app:
            print(f"call detected ({app})", flush=True)
            record(args.user, outbox, until_call_ends)
        time.sleep(POLL)


if __name__ == "__main__":
    main()
