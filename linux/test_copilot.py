"""Run: python3 test_copilot.py   (no audio, no model calls)"""
import sys, unittest
sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
import copilot


class Triggers(unittest.TestCase):
    def test_fires_on_objections_in_both_languages(self):
        for text in ("Your price is above our budget", "That is too expensive for a pilot",
                     "We already work with another agency", "the board wants proof first",
                     "Θα το σκεφτούμε και θα σας πω", "Δεν είμαι σίγουρος για το κόστος"):
            self.assertTrue(copilot.TRIGGERS.search(text), text)

    def test_stays_quiet_on_small_talk(self):
        for text in ("Nice weather today", "Let us start the demo", "Καλημέρα, με ακούτε;"):
            self.assertIsNone(copilot.TRIGGERS.search(text), text)

    def test_auto_advice_is_rate_limited_to_one_per_45_seconds(self):
        calls = []
        advisor = copilot.Advisor.__new__(copilot.Advisor)
        advisor.busy, advisor.last_auto = False, 0.0
        advisor.ask = lambda **kw: calls.append(kw)
        advisor.on_counterpart("your price is too expensive")
        advisor.on_counterpart("and the budget is fixed")
        self.assertEqual(len(calls), 1)


class Brief(unittest.TestCase):
    def test_brief_forbids_inventing_numbers(self):
        prompt = copilot.SYSTEM_PROMPT.format(brief="x", minutes=4, theirs="Them", transcript="y")
        self.assertIn("Never state a price", prompt)
        self.assertIn("at most 3 bullets", prompt.lower())


if __name__ == "__main__":
    unittest.main()
