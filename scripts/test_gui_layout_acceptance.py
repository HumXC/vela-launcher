#!/usr/bin/env python3
"""Offline profile/argument checks; does not launch a GUI or claim runtime acceptance."""
import contextlib
import io
from pathlib import Path
import runpy
import sys
import types
import unittest

sys.dont_write_bytecode = True
h = types.SimpleNamespace(**runpy.run_path(str(Path(__file__).with_name("gui_layout_acceptance.py"))))


class OrdinaryFixtureProfiles(unittest.TestCase):
    def args(self, *extra):
        return h.parse_args(["/unused/freeze.json", "/tmp/vela-gui-current.unused", "1280x720", *extra])

    def test_layout_and_seeded_java_remain_available(self):
        self.assertEqual(h.fixture_profile(self.args()), {"scene": "layout", "hold": "none"})
        args = self.args("--initial-panel", "java", "--java-progress")
        self.assertEqual(h.fixture_profile(args), {"scene": "layout", "hold": "none", "java_progress": True})
        with self.assertRaisesRegex(h.Drift, "requires Java panel"):
            self.args("--java-progress")

    def test_prepared_scene_retains_ordinary_installer_hold(self):
        for hold in ("none", "installer"):
            with self.subTest(hold=hold):
                args = self.args("--fixture-scene", "instance-prepared", "--instance-hold", hold)
                self.assertEqual(h.fixture_profile(args), {"scene": "instance-prepared", "hold": hold})
        with self.assertRaisesRegex(h.Drift, "requires ordinary prepared creation"):
            self.args("--instance-hold", "installer")
        with self.assertRaisesRegex(h.Drift, "Invalid seeded Java progress"):
            self.args("--fixture-scene", "instance-prepared", "--initial-panel", "java", "--java-progress")

    def test_removed_pack_routes_are_rejected_by_argument_parser(self):
        removed = (("--fixture-scene", "pack"), ("--fixture-scene", "pack-prepared"),
                   ("--pack-archive", "modrinth"), ("--pack-hold", "inspection"),
                   ("--pack-adoption-retry",), ("--pack-scenario", "update-replace"))
        for extra in removed:
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    self.args(*extra)
                self.assertEqual(error.exception.code, 2)

    def test_owner_profiles_fail_closed_on_legacy_or_extra_fields(self):
        invalid = ({"scene": "pack-prepared", "archive": "modrinth", "hold": "installer", "adoption_retry": False},
                   {"scene": "layout", "hold": "none", "scenario": "default"},
                   {"scene": "layout", "hold": "none", "archive": "modrinth"},
                   {"scene": "layout", "hold": "inspection"},
                   {"scene": "layout", "hold": False},
                   {"scene": True, "hold": "none"},
                   {"scene": "layout", "hold": "none", "java_progress": 1})
        for profile in invalid:
            with self.subTest(profile=profile), self.assertRaises(h.Drift):
                h.validate_fixture_profile(profile)

    def test_frame_validation_rejects_legacy_profile_before_identity_checks(self):
        tree = types.SimpleNamespace(root="/unused")
        freeze = types.SimpleNamespace(frame=lambda: {"frozen": True})
        frame = {"schema": 1, "root": tree.root, "freeze": freeze.frame(),
                 "initial_panel": "home", "fixture_lifecycle_evidence_limit": h.FIXTURE_LIFECYCLE_LIMIT,
                 "fixture_profile": {"scene": "layout", "archive": "modrinth", "hold": "none", "adoption_retry": False}}
        with self.assertRaisesRegex(h.Drift, "invalid fixture profile fields"):
            h.validate_frame(frame, tree, freeze, owner=True)

    def test_general_native_close_and_resume_arguments_are_preserved(self):
        args = self.args("--allow-native-quit", "--resume", "/unused/closure.json", "--previous-job-collected")
        self.assertTrue(args.allow_native_quit)
        self.assertTrue(args.previous_job_collected)
        self.assertEqual(args.resume, "/unused/closure.json")
        self.assertEqual(args.initial_panel, "home")
        for timeout in (29, 3601):
            with self.subTest(timeout=timeout), self.assertRaisesRegex(h.Drift, "outside finite bounds"):
                self.args("--session-timeout", str(timeout))


if __name__ == "__main__":
    unittest.main()
