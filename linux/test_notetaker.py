"""Run: python3 test_notetaker.py   (synthesises its own audio with ffmpeg, no recording, no network)"""
import json, subprocess, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import notetaker


def audio(dest, spec):
    """spec: list of (seconds, kind) where kind is 'silence', 'room' (quiet noise) or 'talk'."""
    parts = {"silence": "anullsrc=r=16000:cl=mono",
             "room": "anoisesrc=r=16000:c=pink:a=0.0015",
             "talk": "sine=frequency=220:r=16000"}
    inputs, filters = [], []
    for i, (secs, kind) in enumerate(spec):
        inputs += ["-f", "lavfi", "-t", str(secs), "-i", parts[kind]]
        filters.append(f"[{i}:a]")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                    f"{''.join(filters)}concat=n={len(spec)}:v=0:a=1", "-c:a", "libopus", "-b:a", "32k",
                    str(dest)], check=True)


def session(root, name, mic, system):
    d = Path(root) / name
    d.mkdir()
    audio(d / "mic.ogg", mic)
    audio(d / "system.ogg", system)
    (d / "session.json").write_text(json.dumps({
        "user": "john@mrexporttoafrica.com", "host": "test", "source": "linux", "version": 1,
        "selftest": False, "app": "teams-for-linux",
        "started": "2026-09-24T11:51:10Z", "ended": "2026-09-24T12:04:40Z"}))
    return d


class Screening(unittest.TestCase):
    def test_call_detection_blip_is_discarded(self):
        """A WhatsApp blip: the app touched the mic for under a minute and nobody spoke."""
        with tempfile.TemporaryDirectory() as tmp:
            d = session(tmp, "john_blip", [(50, "room")], [(50, "silence")])
            line = notetaker.finalize(d)
        self.assertFalse(d.exists())
        self.assertIn("under the 90 s minimum", line)

    def test_long_call_nobody_spoke_on_is_discarded(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = session(tmp, "john_empty", [(200, "room")], [(200, "silence")])
            line = notetaker.finalize(d)
        self.assertFalse(d.exists())
        self.assertIn("nothing above", line)

    def test_dead_air_in_front_is_trimmed_and_the_conversation_kept(self):
        """The 24 Sep case: John alone in a meet-now meeting, talking only at the end."""
        with tempfile.TemporaryDirectory() as tmp:
            d = session(tmp, "john_waiting", [(300, "room"), (180, "talk")], [(300, "silence"), (180, "talk")])
            line = notetaker.finalize(d)
            self.assertIn("trimmed", line)
            left = notetaker.duration(d / "mic.ogg")
            meta = json.loads((d / "session.json").read_text())
        self.assertGreater(left, 180, "the conversation itself must survive")
        self.assertLess(left, 300, "most of the dead air must be gone")
        self.assertEqual(meta["started"], "2026-09-24T11:55:55Z", "started moves by what was cut")
        self.assertAlmostEqual(meta["trimmed_seconds"], 285, delta=20)

    def test_a_call_that_starts_talking_is_kept_whole(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = session(tmp, "john_real", [(200, "talk")], [(200, "talk")])
            line = notetaker.finalize(d)
            self.assertIn("kept", line)
            self.assertAlmostEqual(notetaker.duration(d / "mic.ogg"), 200, delta=2)
            self.assertNotIn("trimmed_seconds", json.loads((d / "session.json").read_text()))


if __name__ == "__main__":
    unittest.main()
