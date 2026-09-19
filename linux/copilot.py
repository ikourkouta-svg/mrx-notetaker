#!/usr/bin/env python3
"""Live meeting copilot for Doom: listens to the call and advises what to say next.

Transcribes both sides in 10 second chunks with faster-whisper (local, $0) and shows at most 3
bullets in a small always-on-top window. It stays quiet unless you ask (F9), or it hears an
objection, a competitor or a direct question.

F9 asks Gemini Flash: 1.9 s, about EUR 0.0005 a press, and the last 4 minutes of transcript leave
Doom. F10 asks the local model instead, so nothing leaves the machine, but it is much weaker.
Measured on Doom 2026-09-19: Flash 1.9 s; local qwen3:30b kept warm 82 s (useless mid-call, because
live Whisper already uses half the cores); local qwen2.5:7b 1.7 s but usually "nothing to add".
Set PRIVATE_BY_DEFAULT = True to make F9 local and F10 Flash.

The advice is only as good as the brief: ~/.config/meeting-copilot/brief.md holds what we can
promise and what we must not. The model is forbidden to invent a number that is not in there.

Usage: copilot.py [--client NAME] [--brief FILE] [--replay FILE.wav] [--no-ui]
  --client NAME   also load notes from pCloud Clients/<state>/<NAME>/*.md|txt (case-insensitive)
  --replay FILE   feed an audio file as if it were a live call (testing), print advice, exit
  --no-ui         print to the terminal instead of the window (testing)
Hotkeys: F9 advice (Gemini Flash), F10 private (local only), F12 hide/show the window.
"""
import argparse
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import urllib.request
from pathlib import Path

CONF = Path.home() / ".config/meeting-copilot"
BRIEF = CONF / "brief.md"
CHUNK_SECONDS = 10
WINDOW_MINUTES = 4
OLLAMA = ("http://localhost:11434/v1/chat/completions", "qwen2.5:7b")  # only model fast enough warm
PRIVATE_BY_DEFAULT = False  # True = F9 stays on Doom (weaker advice), F10 becomes Flash
GEMINI_ENV = Path.home() / ".doom-secrets/gemini-campaigns.env"
GEMINI_MODEL = "gemini-flash-latest"  # keys minted after May cannot call gemini-2.5-flash
PCLOUD_CLIENTS = Path.home() / "pCloudDrive/01-MRX/Clients"
OURS, THEIRS = "Me", "Them"

# Counterpart lines that deserve advice without being asked: money, proof, competition, delay, a question.
# Built from a list, not a verbose regex: re.X strips the spaces inside a phrase, so "too expensive"
# silently became "tooexpensive" and never matched (caught by the trigger test 2026-09-19).
TRIGGER_PHRASES = [
    "budget", "too expensive", "expensive", "discount", "cheaper", "price", "cost", "quote",
    "competitor", "another agency", "another supplier", "another provider", "we already work",
    "we already have", "proof", "case stud", "reference", "guarantee", "track record",
    "board", "legal", "procurement", "sign", "contract", "terms",
    "think about it", "get back to you", "not sure", "hesitant", "risk",
    "ακριβ", "προϋπολογισμ", "έκπτωση", "κόστος", "τιμή", "εγγύηση", "συμβόλαιο", "ρίσκο",
    "θα το σκεφτ", "θα σας πω", "δεν είμαι σίγουρ", "να το δούμε",
]
TRIGGERS = re.compile("|".join(re.escape(p) for p in TRIGGER_PHRASES), re.I)


SYSTEM_PROMPT = """You sit beside John Kourkoutas during a live business call and tell him what to say next.

BRIEF (the only facts you may rely on):
{brief}

RULES
- At most 3 bullets, at most 12 words each. No preamble, no explanation, no markdown symbols.
- Never state a price, discount, percentage, timeline, client name or result that is not in the BRIEF.
  If a number is needed and the BRIEF does not have it, tell him to ask for theirs instead.
- Prefer a question he can ask over a claim he would have to defend.
- Answer in English even when the call is in Greek.
- If nothing useful can be said, answer exactly: (nothing to add)

Last {minutes} minutes of the call, "{theirs}" is the other side:
{transcript}"""


def brief_text(client=None, path=None):
    if path:
        return Path(path).read_text(encoding="utf-8")[:8000]
    CONF.mkdir(parents=True, exist_ok=True)
    if not BRIEF.exists():
        BRIEF.write_text("""# Live copilot brief

## What we sell
MRX Consulting: market entry, distribution and partner search in Africa.
Amplify Sales: outsourced B2B lead generation, cold email and appointment setting.

## Hard rules
- John personally prepares and sends every proposal.
- Never commission-only work, whatever the client proposes.
- No travel offered to a prospect; offer a Teams call.
- Do not promise a named reference client without checking first.

## Prices and terms
(Fill in: monthly fees, pilot length, minimum engagement, payment terms. The copilot may not
invent any number that is not written here.)
""", encoding="utf-8")
    text = BRIEF.read_text(encoding="utf-8")
    if client:
        for folder in sorted(PCLOUD_CLIENTS.glob(f"*/{client}*")) + sorted(PCLOUD_CLIENTS.glob(f"*/*{client}*")):
            for f in sorted(folder.glob("*.md")) + sorted(folder.glob("*.txt")):
                text += f"\n\n## {folder.name} / {f.name}\n" + f.read_text(encoding="utf-8", errors="replace")[:4000]
            break
    return text[:12000]


class Transcriber:
    """Rolling transcript of the live call, newest last."""

    def __init__(self, on_theirs=None):
        from faster_whisper import WhisperModel
        self.model = WhisperModel("large-v3", device="cpu", compute_type="int8", cpu_threads=8)
        self.lines, self.lock, self.on_theirs = [], threading.Lock(), on_theirs
        self.work = queue.Queue()

    def add(self, path, speaker):
        self.work.put((path, speaker))

    def run(self):
        while True:
            path, speaker = self.work.get()
            try:
                segments, _ = self.model.transcribe(str(path), multilingual=True, vad_filter=True,
                                                    beam_size=1, condition_on_previous_text=False)
                text = " ".join(s.text.strip() for s in segments).strip()
            except Exception as e:
                print(f"transcribe failed: {e}", file=sys.stderr)
                continue
            if not text:
                continue
            with self.lock:
                self.lines.append((time.time(), speaker, text))
            print(f"{speaker}: {text}", flush=True)
            if speaker == THEIRS and self.on_theirs:
                self.on_theirs(text)

    def window(self, minutes=WINDOW_MINUTES):
        cutoff = time.time() - minutes * 60
        with self.lock:
            return "\n".join(f"{sp}: {t}" for ts, sp, t in self.lines if ts >= cutoff)


def ask_local(prompt):
    url, model = OLLAMA
    body = json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}],
                       "temperature": 0.3, "max_tokens": 160, "keep_alive": "2h"}).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=120))["choices"][0]["message"]["content"].strip()


def ask_gemini(prompt):
    key = dict(re.findall(r"^([A-Z_]+)=(.*)$", GEMINI_ENV.read_text(), re.M))["GEMINI_API_KEY"].strip().strip('"')
    # thinkingBudget 0: flash otherwise spends the whole output budget on hidden thinking and
    # returns a truncated fragment (seen 2026-09-19: 284 thought tokens, finishReason MAX_TOKENS).
    body = json.dumps({"contents": [{"parts": [{"text": prompt}]}],
                       "generationConfig": {"temperature": 0.3, "maxOutputTokens": 300,
                                            "thinkingConfig": {"thinkingBudget": 0}}}).encode()
    req = urllib.request.Request(f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent",
                                 body, {"Content-Type": "application/json", "x-goog-api-key": key})
    answer = json.load(urllib.request.urlopen(req, timeout=60))
    return answer["candidates"][0]["content"]["parts"][0]["text"].strip()


class Advisor:
    def __init__(self, transcriber, brief, show):
        self.t, self.brief, self.show = transcriber, brief, show
        self.busy, self.last_auto = False, 0.0

    def ask(self, private=PRIVATE_BY_DEFAULT, reason=""):
        if self.busy:
            return
        transcript = self.t.window()
        if not transcript:
            return self.show("(nothing heard yet)", "")
        self.busy = True
        self.show("thinking...", reason)
        prompt = SYSTEM_PROMPT.format(brief=self.brief, minutes=WINDOW_MINUTES, theirs=THEIRS, transcript=transcript)

        def work():
            started = time.time()
            try:
                answer = ask_local(prompt) if private else ask_gemini(prompt)
            except Exception as e:
                answer = f"advice failed: {type(e).__name__}"
            self.show(answer, f"{'local' if private else 'Gemini EUR0.0005'} {time.time() - started:.0f}s {reason}")
            self.busy = False

        threading.Thread(target=work, daemon=True).start()

    def on_counterpart(self, text):
        hit = TRIGGERS.search(text)
        if hit and time.time() - self.last_auto > 45:
            self.last_auto = time.time()
            self.ask(reason=f"heard “{hit.group(0)}”")


# ---------- audio ----------

def segmenter(source, out_dir, prefix):
    out_dir.mkdir(parents=True, exist_ok=True)
    return subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "pulse", "-i", source,
                             "-ac", "1", "-ar", "16000", "-f", "segment", "-segment_time", str(CHUNK_SECONDS),
                             str(out_dir / f"{prefix}_%05d.wav")], stdin=subprocess.DEVNULL)


def watch_chunks(out_dir, prefix, speaker, transcriber):
    """A chunk is complete once ffmpeg has started the next one."""
    seen = set()
    while True:
        files = sorted(out_dir.glob(f"{prefix}_*.wav"))
        for f in files[:-1]:
            if f not in seen:
                seen.add(f)
                transcriber.add(f, speaker)
        time.sleep(1)


# ---------- window ----------

def build_window(advisor):
    import tkinter as tk
    root = tk.Tk()
    root.title("MRX Copilot")
    root.attributes("-topmost", True)
    root.geometry("460x210+40+40")
    root.configure(bg="#14161a")
    body = tk.Label(root, text="listening...", justify="left", anchor="nw", wraplength=430,
                    font=("DejaVu Sans", 12), fg="#f2f4f8", bg="#14161a")
    body.pack(fill="both", expand=True, padx=12, pady=(10, 4))
    status = tk.Label(root, text="F9 advice   F10 private   F12 hide", anchor="w",
                      font=("DejaVu Sans", 9), fg="#8b93a1", bg="#14161a")
    status.pack(fill="x", padx=12, pady=(0, 8))
    row = tk.Frame(root, bg="#14161a")
    row.pack(fill="x", padx=8, pady=(0, 8))
    tk.Button(row, text="Advice", command=lambda: advisor.ask(), bg="#23272e", fg="#f2f4f8", relief="flat").pack(side="left", padx=4)
    tk.Button(row, text="Private", command=lambda: advisor.ask(private=not PRIVATE_BY_DEFAULT), bg="#23272e", fg="#f2f4f8", relief="flat").pack(side="left", padx=4)

    def show(text, note):
        body.after(0, lambda: (body.config(text=text), status.config(text=f"F9 advice   F10 private   F12 hide    {note}")))

    root.bind("<F9>", lambda _: advisor.ask(reason="F9"))
    root.bind("<F10>", lambda _: advisor.ask(private=not PRIVATE_BY_DEFAULT, reason="F10"))
    return root, show


def global_hotkeys(advisor, root):
    """X11 grabs, so the keys work while Teams has the focus."""
    try:
        from Xlib import X, XK, display
    except ImportError:
        return
    d = display.Display()
    screen = d.screen().root
    keys = {d.keysym_to_keycode(XK.string_to_keysym(k)): k for k in ("F9", "F10", "F12")}
    for code in keys:
        for mod in (X.AnyModifier,):
            screen.grab_key(code, mod, True, X.GrabModeAsync, X.GrabModeAsync)
    screen.change_attributes(event_mask=X.KeyPressMask)

    def loop():
        hidden = False
        while True:
            event = d.next_event()
            if event.type != X.KeyPress:
                continue
            key = keys.get(event.detail)
            if key == "F9":
                advisor.ask(reason="F9")
            elif key == "F10":
                advisor.ask(private=not PRIVATE_BY_DEFAULT, reason="F10")
            elif key == "F12" and root is not None:
                hidden = not hidden
                root.after(0, root.withdraw if hidden else root.deiconify)

    threading.Thread(target=loop, daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--client")
    ap.add_argument("--brief")
    ap.add_argument("--replay")
    ap.add_argument("--no-ui", action="store_true")
    args = ap.parse_args()
    brief = brief_text(args.client, args.brief)

    if args.replay:
        transcriber = Transcriber()
        threading.Thread(target=transcriber.run, daemon=True).start()
        work = Path("/tmp/copilot-replay")
        subprocess.run(["rm", "-rf", str(work)], check=False)
        work.mkdir(parents=True)
        subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", args.replay, "-ac", "1",
                        "-ar", "16000", "-f", "segment", "-segment_time", str(CHUNK_SECONDS),
                        str(work / "them_%05d.wav")], check=True)
        for f in sorted(work.glob("them_*.wav")):
            transcriber.add(f, THEIRS)
        while not transcriber.work.empty():
            time.sleep(1)
        time.sleep(2)
        advisor = Advisor(transcriber, brief, lambda text, note: print(f"\n=== advice ({note})\n{text}"))
        advisor.ask()
        while advisor.busy:
            time.sleep(0.5)
        return

    # The advisor needs the transcript, the window needs the advisor, so the window is wired last.
    holder = {}
    transcriber = Transcriber(on_theirs=lambda text: holder["advisor"].on_counterpart(text))
    advisor = Advisor(transcriber, brief, lambda text, note: print(f"[{note}] {text}", flush=True))
    holder["advisor"] = advisor
    root = None
    if not args.no_ui:
        root, show_fn = build_window(advisor)
        advisor.show = show_fn
    global_hotkeys(advisor, root)

    threading.Thread(target=transcriber.run, daemon=True).start()
    work = Path("/tmp/copilot-live")
    subprocess.run(["rm", "-rf", str(work)], check=False)
    sink = subprocess.run(["pactl", "get-default-sink"], capture_output=True, text=True).stdout.strip()
    procs = [segmenter("@DEFAULT_SOURCE@", work, "me"), segmenter(f"{sink}.monitor", work, "them")]
    for prefix, speaker in (("me", OURS), ("them", THEIRS)):
        threading.Thread(target=watch_chunks, args=(work, prefix, speaker, transcriber), daemon=True).start()
    print("copilot listening; F9 advice, F10 private", flush=True)
    try:
        root.mainloop() if root is not None else threading.Event().wait()
    finally:
        for p in procs:
            p.terminate()


if __name__ == "__main__":
    main()
