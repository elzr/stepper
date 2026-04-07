#!/usr/bin/env python3
"""Tests for update-bear-weeks.py — L005 weekly updater.

Run: python3 -m pytest test_update_bear_weeks.py -v
  or: python3 test_update_bear_weeks.py
"""
import datetime
import importlib.util
import os
import tempfile
import unittest

# Import the script as a module (hyphenated filename needs importlib)
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "update_bear_weeks",
    os.path.join(SCRIPT_DIR, "update-bear-weeks.py"),
)
ubw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ubw)


# -- Path resolution (the bug that broke 3 weeks) ---------------------------

class TestPathResolution(unittest.TestCase):
    """PROJECT_ROOT must point at stepper/, not one level above."""

    def test_project_root_ends_with_stepper(self):
        self.assertTrue(
            ubw.PROJECT_ROOT.endswith("stepper"),
            f"PROJECT_ROOT is {ubw.PROJECT_ROOT} — should end with 'stepper'",
        )

    def test_jsonc_path_exists(self):
        self.assertTrue(os.path.isfile(ubw.JSONC_PATH), f"Missing: {ubw.JSONC_PATH}")

    def test_week_data_path_exists(self):
        self.assertTrue(os.path.isfile(ubw.WEEK_DATA_PATH), f"Missing: {ubw.WEEK_DATA_PATH}")


# -- Week computation -------------------------------------------------------

class TestComputeWeeks(unittest.TestCase):
    """compute_weeks(today) returns the 6-var dict for bear-notes.jsonc."""

    def test_mid_year_monday(self):
        r = ubw.compute_weeks(datetime.date(2026, 4, 7))  # Mon of ISO week 15
        self.assertEqual(r["weekNum"], "15")
        self.assertEqual(r["pastWeekNum"], "14")
        self.assertEqual(r["nextWeekNum"], "16")
        self.assertEqual(r["weekDays"], "6-12apr2026")
        self.assertEqual(r["pastWeekDays"], "30mar-5apr2026")
        self.assertEqual(r["nextWeekDays"], "13-19apr2026")

    def test_week_1_wraps_past_to_53(self):
        r = ubw.compute_weeks(datetime.date(2026, 1, 1))  # Thu of ISO week 1
        self.assertEqual(r["weekNum"], "1")
        self.assertEqual(r["pastWeekNum"], "53")
        self.assertEqual(r["nextWeekNum"], "2")

    def test_week_53_wraps_next_to_1(self):
        r = ubw.compute_weeks(datetime.date(2026, 12, 31))  # Thu of ISO week 53
        self.assertEqual(r["weekNum"], "53")
        self.assertEqual(r["pastWeekNum"], "52")
        self.assertEqual(r["nextWeekNum"], "1")

    def test_all_six_keys_present(self):
        r = ubw.compute_weeks(datetime.date(2026, 6, 15))
        for key in ("weekNum", "weekDays", "pastWeekNum", "pastWeekDays",
                     "nextWeekNum", "nextWeekDays"):
            self.assertIn(key, r, f"Missing key: {key}")

    def test_day_ranges_are_nonempty_strings(self):
        r = ubw.compute_weeks(datetime.date(2026, 4, 7))
        for key in ("weekDays", "pastWeekDays", "nextWeekDays"):
            self.assertIsInstance(r[key], str)
            self.assertTrue(len(r[key]) > 0, f"{key} is empty")


# -- JSONC content update ---------------------------------------------------

SAMPLE_STALE = """\
{
  "vars": {
    "weekNum": "14",                   // current
    "weekDays": "30mar-5apr2026",

    "pastWeekNum": "13",              // R\\u2318 (right-cmd)
    "pastWeekDays": "23-29mar2026",     // R\\u2318 (right-cmd)

    "nextWeekNum": "15",              // R\\u2325 (right-option)
    "nextWeekDays": "6-12apr2026"    // R\\u2325 (right-option)
  },
  "notes": []
}
"""

WEEK15_REPLACEMENTS = {
    "weekNum": "15", "weekDays": "6-12apr2026",
    "pastWeekNum": "14", "pastWeekDays": "30mar-5apr2026",
    "nextWeekNum": "16", "nextWeekDays": "13-19apr2026",
}

WEEK14_REPLACEMENTS = {
    "weekNum": "14", "weekDays": "30mar-5apr2026",
    "pastWeekNum": "13", "pastWeekDays": "23-29mar2026",
    "nextWeekNum": "15", "nextWeekDays": "6-12apr2026",
}


class TestUpdateContent(unittest.TestCase):
    """update_jsonc_content(lines, replacements) -> (new_lines, changed)."""

    def test_updates_stale_values(self):
        lines = SAMPLE_STALE.splitlines(keepends=True)
        new_lines, changed = ubw.update_jsonc_content(lines, WEEK15_REPLACEMENTS)
        self.assertTrue(changed)
        content = "".join(new_lines)
        self.assertIn('"weekNum": "15"', content)
        self.assertIn('"weekDays": "6-12apr2026"', content)
        self.assertIn('"pastWeekNum": "14"', content)
        self.assertIn('"nextWeekNum": "16"', content)

    def test_idempotent_when_current(self):
        lines = SAMPLE_STALE.splitlines(keepends=True)
        _, changed = ubw.update_jsonc_content(lines, WEEK14_REPLACEMENTS)
        self.assertFalse(changed)

    def test_preserves_comments(self):
        lines = SAMPLE_STALE.splitlines(keepends=True)
        new_lines, _ = ubw.update_jsonc_content(lines, WEEK15_REPLACEMENTS)
        content = "".join(new_lines)
        self.assertIn("// current", content)
        self.assertIn("// R", content)

    def test_preserves_non_var_lines(self):
        lines = SAMPLE_STALE.splitlines(keepends=True)
        new_lines, _ = ubw.update_jsonc_content(lines, WEEK15_REPLACEMENTS)
        content = "".join(new_lines)
        self.assertIn('"notes": []', content)


# -- End-to-end with temp file ----------------------------------------------

class TestEndToEnd(unittest.TestCase):
    """update_file(path, today) updates a jsonc file in place."""

    def test_updates_stale_file(self):
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".jsonc", delete=False
        ) as f:
            f.write(SAMPLE_STALE)
            tmp = f.name
        try:
            changed = ubw.update_file(tmp, datetime.date(2026, 4, 7))
            self.assertTrue(changed)
            with open(tmp) as f:
                content = f.read()
            self.assertIn('"weekNum": "15"', content)
            self.assertIn('"nextWeekDays": "13-19apr2026"', content)
        finally:
            os.unlink(tmp)

    def test_no_write_when_current(self):
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".jsonc", delete=False
        ) as f:
            f.write(SAMPLE_STALE)
            tmp = f.name
        try:
            mtime_before = os.path.getmtime(tmp)
            changed = ubw.update_file(tmp, datetime.date(2026, 3, 31))  # week 14
            self.assertFalse(changed)
            mtime_after = os.path.getmtime(tmp)
            self.assertEqual(mtime_before, mtime_after, "File was written when it shouldn't have been")
        finally:
            os.unlink(tmp)


if __name__ == "__main__":
    unittest.main()
