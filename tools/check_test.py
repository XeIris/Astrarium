#!/usr/bin/env python3
"""Scheduling and pass-record tests for check.py; no engine or renderer required."""
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import check
from check import Check

# Writes when it started and ended, so a test can tell which children overlapped.
CHILD = ("import sys, time\n"
         "open(sys.argv[1], 'w').write(repr(time.time()) + ' ')\n"
         "time.sleep(float(sys.argv[2]))\n"
         "open(sys.argv[1], 'a').write(repr(time.time()))\n"
         "sys.exit(int(sys.argv[3]))\n")


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="astrarium-check-self-")
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name).resolve()
        # Progress keeps learned times and run status here: not in the clone's own.
        runs = patch.object(check, "runs_dir", lambda: self.output / "runs")
        runs.start()
        self.addCleanup(runs.stop)

    def child(self, name, seconds, code=0, **fields):
        return Check(name, [sys.executable, "-c", CHILD, str(self.output / f"{name}.span"), str(seconds), str(code)], None, 30, **fields)

    def span(self, name):
        return [float(value) for value in (self.output / f"{name}.span").read_text().split()]

    def run_plan(self, plan, jobs, keep_going=False):
        options = SimpleNamespace(godot="unused", timeout=None, allow_macos_ca_error=False, jobs=jobs, keep_going=keep_going)
        report = {"results": []}
        with redirect_stdout(io.StringIO()):
            complete = check.run_plan(plan, self.output, options, None, report, [f"key-{c.name}" for c in plan])
        return complete, report["results"]

    def test_launch_order(self):
        expected = [300.0, 2.0, None, 40.0, 0.5, 90.0]
        self.assertEqual(check.launch_order(range(6), expected, 4), [4, 1, 2, 0, 5, 3])
        self.assertEqual(check.launch_order(range(6), expected, 1), [4, 1, 2, 0, 3, 5])

    def test_lane_takes_turns_beside_the_rest(self):
        # Seconds apart, so a slow runner's process start-up cannot reorder them.
        plan = [self.child("window-a", 1.5, lane="window"), self.child("window-b", 1.5, lane="window"),
                self.child("headless", 3.0)]
        complete, results = self.run_plan(plan, jobs=3)
        self.assertTrue(complete)
        self.assertEqual([r["name"] for r in results], ["window-a", "window-b", "headless"])
        self.assertEqual([r["key"] for r in results], ["key-window-a", "key-window-b", "key-headless"])
        a, b, headless = self.span("window-a"), self.span("window-b"), self.span("headless")
        first, second = sorted([a, b])
        self.assertLessEqual(first[1], second[0], "two checks in one lane ran at once")
        self.assertLess(headless[0], first[1], "the headless check waited for the lane")
        self.assertLess(second[0], headless[1], "the lane waited for the headless check")

    def test_lane_is_extra_only_beside_other_jobs(self):
        plan = [self.child("window", 2.5, lane="window"), self.child("one", 2.5), self.child("two", 2.5)]
        self.assertTrue(self.run_plan(plan, jobs=2)[0])
        window, one, two = self.span("window"), self.span("one"), self.span("two")
        self.assertLess(max(window[0], one[0], two[0]), min(window[1], one[1], two[1]), "two jobs and the window did not overlap")
        plan = [self.child("window", 0.2, lane="window"), self.child("one", 0.2), self.child("two", 0.2)]
        self.assertTrue(self.run_plan(plan, jobs=1)[0])
        spans = sorted(self.span(name) for name in ("window", "one", "two"))
        self.assertTrue(all(a[1] <= b[0] for a, b in zip(spans, spans[1:])), "--jobs 1 ran two at once")

    def test_alone_runs_by_itself(self):
        plan = [self.child("before", 0.4), self.child("alone", 0.4, alone=True), self.child("after", 0.4)]
        self.assertTrue(self.run_plan(plan, jobs=3)[0])
        self.assertLessEqual(self.span("before")[1], self.span("alone")[0])
        self.assertLessEqual(self.span("alone")[1], self.span("after")[0])

    def test_failure_stops_or_keeps_going(self):
        plan = [self.child("fails", 0.1, code=3), self.child("later", 0.1)]
        complete, results = self.run_plan(plan, jobs=1)
        self.assertFalse(complete)
        self.assertEqual([(r["name"], r["problem"]) for r in results], [("fails", "child exited 3")])
        self.assertFalse((self.output / "later.span").exists())
        complete, results = self.run_plan(plan, jobs=1, keep_going=True)
        self.assertFalse(complete)
        self.assertEqual([(r["name"], r["problem"]) for r in results], [("fails", "child exited 3"), ("later", None)])

    def test_pass_key_ignores_where_it_ran(self):
        def key(output, marker="^DONE$", around="a", allow_macos_ca_error=False):
            command = ["godot", "--path", str(check.ROOT), f"out={output / 'x.json'}"]
            return check.pass_key(Check("x", command, marker, 60), output, "godot", around, allow_macos_ca_error)
        self.assertEqual(key(self.output / "one"), key(self.output / "two"))
        self.assertNotIn(str(check.ROOT), key(self.output))
        self.assertNotEqual(key(self.output), key(self.output, marker="^OTHER$"))
        self.assertNotEqual(key(self.output), key(self.output, around="b"))
        self.assertNotEqual(key(self.output), key(self.output, allow_macos_ca_error=True))

    @unittest.skipUnless(os.name == "posix", "pass recording uses POSIX change times")
    def test_only_stable_inputs_are_recorded(self):
        root = self.output / "project"
        root.mkdir()
        (root / "native").mkdir()
        (root / ".gitignore").write_text("/native/*.so\n")
        source, library = root / "check.gd", root / "native/kernel.so"
        source.write_text("first")
        library.write_bytes(b"first")
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "add", "check.gd"], cwd=root, check=True)
        godot = str(Path(sys.executable).resolve())
        plan = [Check("probe", ["probe"], None, 30)]

        def run(change):
            def finish(plan, output, options, guard, report, keys):
                change()
                report["results"].append({"name": "probe", "problem": None, "key": keys[0]})
                return True

            with patch.object(sys, "argv", ["check.py", "--godot", godot, "--log-dir", str(self.output)]), \
                 patch.object(check, "run_plan", side_effect=finish), patch.object(check, "record_passes") as record, \
                 patch.object(check, "print_times"), redirect_stdout(io.StringIO()):
                self.assertEqual(check.main(), 0)
            return record.call_args.args if record.called else None

        def rewrite_and_restore(path):
            original = path.read_bytes()
            info = path.stat()
            path.write_bytes(b"intermediate")
            path.write_bytes(original)
            os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))

        with patch.object(check, "ROOT", root), patch.object(check, "checks", return_value=plan):
            first = run(lambda: None)
            self.assertIsNotNone(first)
            self.assertIsNone(run(lambda: rewrite_and_restore(source)))
            self.assertIsNone(run(lambda: rewrite_and_restore(library)))
            self.assertIsNone(run(lambda: library.write_bytes(b"second")))
            second = run(lambda: None)
            self.assertIsNotNone(second)
            self.assertEqual(first[1], second[1])  # same Git tree
            self.assertNotEqual(first[2], second[2])  # different pass keys

    def test_passes_are_kept_newest_first(self):
        folder = self.output / "passes"
        for tree in ["t%d" % i for i in range(check.PASS_KEEP + 2)] + ["t3"]:
            check.record_passes(folder, tree, ["k"])
        trees = [record["tree"] for record in check.read_passes(folder)["k"]]
        self.assertEqual(len(trees), check.PASS_KEEP)
        self.assertEqual(trees[0], "t3")
        self.assertEqual(len(set(trees)), len(trees))
        (folder / "passes.json").write_text("[")
        self.assertEqual(check.read_passes(folder), {})

    def test_passed_unchanged_follows_the_rules(self):
        plan = [Check("import", [], None, 1), Check("sciencecheck", [], None, 1), Check("galaxycheck", [], None, 1)]
        keys = ["i", "s", "g"]
        passes = {key: [{"tree": "pruned", "utc": "x"}, {"tree": "galaxy-edit", "utc": "x"}] for key in keys}
        changes = {"pruned": None, "galaxy-edit": ["sim/galaxy/gal_units.gd", "docs/notes.md"], "same": []}
        hits = check.passed_unchanged(plan, keys, [], passes, "now", lambda earlier, tree: changes[earlier])
        self.assertEqual(sorted(hits), [1])
        self.assertEqual(hits[1]["tree"], "galaxy-edit")
        # An unmapped path selects the dev suite, so a dev check is not carried over it.
        hits = check.passed_unchanged(plan, keys, [plan[1]], {"s": [{"tree": "same"}], "g": [{"tree": "same"}]}, "now",
                                      lambda earlier, tree: ["somewhere/new.gd"])
        self.assertEqual(sorted(hits), [2])
        self.assertEqual(check.passed_unchanged(plan, keys, [], {"s": ["malformed", {"utc": "x"}]}, "now", lambda *a: []), {})


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CheckTests))
    if result.wasSuccessful():
        print("CHECK SELF-CHECK PASS")
    sys.exit(0 if result.wasSuccessful() else 1)
