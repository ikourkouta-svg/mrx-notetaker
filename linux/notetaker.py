#!/usr/bin/env python3
"""Automatic call recorder for Linux (PipeWire/PulseAudio).

Starts when a meeting app (Teams, Chrome, Zoom...) opens the microphone and stops 45 s after it
releases it. Writes two tracks, mic (you) and system (everyone else), then session.json LAST
into OUTBOX/<user>_<timestamp>/, where the transcription job picks it up.

Before a session leaves for the outbox it is screened: call-detection blips and calls nobody
spoke on are discarded, and dead air in front of the conversation is trimmed off, so the
transcription job does not spend Whisper time on them.

Usage: notetaker.py --user john@mrexporttoafrica.com [--outbox DIR] [--selftest]
       notetaker.py --finalize SESSION_DIR   (screen a session already written, e.g. a backlog one)
"""
import argparse
import datetime as dt
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import time
from pathlib import Path

# Doom is John's own machine and its summaries reach John alone, so personal call apps are included
# here. The macOS build deliberately leaves them out: Costas was told they are never recorded.
MEETING_APPS = ("teams-for-linux", "teams", "chrome", "chromium", "msedge", "microsoft-edge", "firefox",
                "zoom", "webex", "ciscocollabhost", "viber", "whatsapp", "mrx-whats", "telegram", "signal-desktop",
                "skype")
POLL, GRACE = 3, 45

# Screening. Every threshold is an env override so a real short call can be let through without
# a code change. Levels are mean (RMS) dB over a WINDOW-second block: the mean separates talking
# from an empty room, while peaks do not (a Teams join chime peaks as loud as speech).
WINDOW = 15
MIN_SECONDS = float(os.environ.get("NOTETAKER_MIN_SECONDS", 90))
SPEECH_DB = float(os.environ.get("NOTETAKER_SPEECH_DB", -45))      # no block above this = nobody spoke
TRIM_MARGIN_DB = float(os.environ.get("NOTETAKER_TRIM_MARGIN_DB", 12))  # speech = within this of the loudest block
LEAD_IN = float(os.environ.get("NOTETAKER_LEAD_IN", 15))           # kept in front of the first speech
MIN_TRIM = float(os.environ.get("NOTETAKER_MIN_TRIM", 60))         # below this, not worth re-encoding


def meeting_app_on_mic():
    out = subprocess.run(["pactl", "-f", "json", "list", "source-outputs"], capture_output=True, text=True).stdout
    for o in json.loads(out or "[]"):
        binary = (o["properties"].get("application.process.binary") or "").lower()
        if binary.startswith(MEETING_APPS):
            return binary
    return None


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of",
                          "csv=p=0", str(path)], capture_output=True, text=True).stdout.strip()
    try:
        return float(out)
    except ValueError:
        return 0.0


def window_levels(path):
    """[(second, mean dB)] per WINDOW seconds, in one ffmpeg pass.

    Read the timestamp ffmpeg prints rather than counting blocks: a silent block reports -inf and
    would otherwise shift every later block earlier than it really is.
    """
    out = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(path), "-af",
         f"aresample=16000,asetnsamples=n={16000 * WINDOW},astats=metadata=1:reset=1,"
         "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-", "-f", "null", "-"],
        capture_output=True, text=True).stdout
    pairs = re.findall(r"pts_time:(\d+\.?\d*)\s*\nlavfi\.astats\.Overall\.RMS_level=(\S+)", out)
    return [(float(t), -120.0 if lvl.endswith("inf") else float(lvl)) for t, lvl in pairs]


def speech_start(levels):
    """Second where talking starts, or None when no block is loud enough to be speech.

    The threshold follows the recording: speech is within TRIM_MARGIN_DB of the loudest block, and
    never below SPEECH_DB. Two blocks in a row must pass, so one chime cannot open the call.
    """
    if not levels:
        return None
    loudest = max(db for _, db in levels)
    if loudest < SPEECH_DB:
        return None
    threshold = max(loudest - TRIM_MARGIN_DB, SPEECH_DB)
    for (second, db), (_, nxt) in zip(levels, levels[1:]):
        if db >= threshold and nxt >= threshold:
            return second
    return None


def trim(path, seconds):
    cut = path.with_suffix(".cut.ogg")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{seconds:.3f}",
                    "-i", str(path), "-c:a", "libopus", "-b:a", "32k", str(cut)], check=True)
    cut.replace(path)


def finalize(folder):
    """Screen a finished session in place. Returns the line describing what was done.

    Discards a session too short to be a call or with no speech on either track (the folder is
    removed), and otherwise trims dead air in front of the conversation, moving `started` forward
    by the same amount so the summary still says when people actually talked.
    """
    folder = Path(folder)
    meta = json.loads((folder / "session.json").read_text())
    tracks = [folder / f"{name}.ogg" for name in ("mic", "system")]
    tracks = [t for t in tracks if t.exists()]
    length = max([duration(t) for t in tracks], default=0.0)

    if length < MIN_SECONDS:
        shutil.rmtree(folder)
        return f"discarded {folder.name}: {length:.0f} s, under the {MIN_SECONDS:.0f} s minimum ({meta.get('app', '?')})"

    starts = [s for s in (speech_start(window_levels(t)) for t in tracks) if s is not None]
    if not starts:
        shutil.rmtree(folder)
        return f"discarded {folder.name}: {length:.0f} s with nothing above {SPEECH_DB:.0f} dB ({meta.get('app', '?')})"

    cut = max(0.0, min(starts) - LEAD_IN)
    if cut < MIN_TRIM or length - cut < MIN_SECONDS:
        return f"kept {folder.name}: {length:.0f} s, talking from {min(starts):.0f} s"
    for t in tracks:
        trim(t, cut)
    started = dt.datetime.fromisoformat(meta["started"].replace("Z", "+00:00")) + dt.timedelta(seconds=cut)
    meta["started"] = started.isoformat().replace("+00:00", "Z")
    meta["trimmed_seconds"] = round(cut, 1)
    (folder / "session.json").write_text(json.dumps(meta))
    return f"trimmed {folder.name}: cut {cut:.0f} s of dead air, {length - cut:.0f} s left"


def ffmpeg(source, dest):
    return subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "pulse", "-i", source,
                             "-ac", "1", "-c:a", "libopus", "-b:a", "32k", str(dest)], stdin=subprocess.DEVNULL)


def record(user, outbox, stop_when, selftest=False, app=None):
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
        "user": user, "host": socket.gethostname(), "source": "linux", "version": 1, "selftest": selftest, "app": app,
        "started": started.isoformat().replace("+00:00", "Z"), "ended": ended.isoformat().replace("+00:00", "Z")}))
    if not selftest:  # the installer's 10 s self-test must reach the outbox, short and quiet as it is
        print(finalize(work), flush=True)
        if not work.exists():
            return
    shutil.move(str(work), outbox / name)
    print(f"saved {outbox / name} ({(ended - started).seconds // 60} min)", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--user")
    ap.add_argument("--outbox", default=str(Path.home() / "MeetingRecordings/outbox"))
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--finalize", help="screen one session folder that is already written, then exit")
    args = ap.parse_args()
    if args.finalize:
        return print(finalize(args.finalize))
    if not args.user:
        ap.error("--user is required")
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
            record(args.user, outbox, until_call_ends, app=app)
        time.sleep(POLL)


if __name__ == "__main__":
    main()
