#!/usr/bin/env python3
"""Failure-contract tests for reference captures; no renderer required."""
import base64
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zlib

from reference_shots import CaptureError, ROOT, capture, jobs, select


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00")) + chunk(b"IEND", b"")


class ReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="astrarium-reference-self-")
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name).resolve()
        self.child = self.output / "child.py"
        self.child.write_text('''import base64, json, os, pathlib, sys, time
case = os.environ.get("CAPTURE_CASE", "good")
output = pathlib.Path(sys.argv[1])
if case == "timeout": time.sleep(10)
if case == "child": sys.exit(37)
if case == "missing": sys.exit(0)
if case != "missing-png": (output / "shot.png").write_bytes(base64.b64decode(os.environ["CAPTURE_PNG"]) if case != "png" else b"bad png")
if case != "missing-json": (output / "shot.json").write_text("{" if case == "json" else "{}" if case == "empty-json" else '{"met": 1}')
if case == "script": print("SCRIPT ERROR: injected")
if case == "shader": print("SHADER ERROR: injected")
if case == "engine": print("ERROR: injected")
if case == "web": print("FAIL shot injected")
if case == "exception": print("[page exception] injected")
if case == "diff": print("CHECK DIFF injected")
if case == "partial-marker": print("capture done partially")
elif case != "marker": print("capture done")
if case == "duplicate": print("capture done")
''')
        self.config = SimpleNamespace(godot="not-an-engine", timeout=2, background=False, allow_macos_ca_error=False)

    def result(self, case):
        job = ("shot", self.output, [sys.executable, str(self.child), str(self.output)],
               [self.output / "shot.png", self.output / "shot.json"], ["capture done"], 2)
        env = {"CAPTURE_CASE": case, "CAPTURE_PNG": base64.b64encode(png()).decode()}
        with patch.dict(os.environ, env), redirect_stdout(io.StringIO()):
            return capture(job, 0, self.config)

    def test_complete_capture(self):
        self.assertIsNone(self.result("good")["problem"])

    def test_failures(self):
        for case in ("child", "missing", "script", "shader", "engine", "web", "exception", "diff",
                     "marker", "partial-marker", "duplicate", "missing-png", "missing-json", "png", "json", "empty-json"):
            with self.subTest(case=case):
                self.assertIsNotNone(self.result(case)["problem"])

    def test_stale_output_cannot_pass(self):
        (self.output / "shot.png").write_bytes(png())
        (self.output / "shot.json").write_text('{"met": 1}')
        self.assertIsNotNone(self.result("missing")["problem"])
        self.assertFalse((self.output / "shot.png").exists())
        self.assertFalse((self.output / "shot.json").exists())

    def test_timeout(self):
        self.config.timeout = 0.1
        result = self.result("timeout")
        self.assertEqual(result["problem"], "timeout")
        self.assertEqual(result["exit_code"], 124)

    def test_selection(self):
        self.assertEqual(select([], {"sun": 1}), ["sun"])
        for requested, available in (([], {}), (["unknown"], {"sun": 1}), (["sun", "sun"], {"sun": 1})):
            with self.subTest(requested=requested), self.assertRaises(CaptureError):
                select(requested, available)

    def test_missing_fixture(self):
        with self.assertRaises(CaptureError):
            list(jobs("stars", [str(self.output), str(self.output), "sun"], "unused"))

    def test_wrapper_failure_and_report(self):
        # An existing executable that cannot render must never produce a passing report.
        env = {**os.environ, "GODOT": sys.executable, "TIMEOUT": "2"}
        for script, args in (("startest_all.sh", [str(ROOT / "tools/fixtures/stars/state"), str(self.output), "sun"]),
                             ("coursetest.sh", [str(self.output), "kepler"]),
                             ("flightshots.sh", [str(self.output), "sv_launch", "godot"])):
            with self.subTest(script=script):
                child = subprocess.run(["sh", str(ROOT / "tools" / script), *args], env=env,
                                       text=True, capture_output=True, timeout=15)
                self.assertNotEqual(child.returncode, 0, child.stdout + child.stderr)
                report = json.loads((self.output / "reference-report.json").read_text())
                self.assertFalse(report["complete"])
                self.assertTrue(report["results"][0]["problem"])

    def test_flight_output_manifest(self):
        generated = list(jobs("flight", [str(self.output), "sv_launch", "godot"], "unused"))
        self.assertEqual(len(generated), 1)
        files = generated[0][3]
        self.assertIn(self.output / "godot/sv_tp60.hud.png", files)
        self.assertEqual(len(generated[0][4]), 4)


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ReferenceTests))
    if result.wasSuccessful():
        print("REFERENCE SHOTS SELF-CHECK PASS")
    sys.exit(0 if result.wasSuccessful() else 1)
