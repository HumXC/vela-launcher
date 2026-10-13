#!/usr/bin/env python3
"""Offline regression tests for loader acceptance result classification."""
import unittest

from loader_acceptance import acceptance_failed


class AcceptanceResultTests(unittest.TestCase):
    def report(self):
        return {
            "live_residual_pids": [],
            "binary_replaced_during_run": False,
            "published": True,
            "receipt_hash_verified": True,
            "client_hash_verified": True,
            "metadata_hash_verified": True,
        }

    def test_stable_verified_run_succeeds(self):
        self.assertFalse(acceptance_failed(0, None, False, self.report()))

    def test_detected_binary_replacement_invalidates_otherwise_verified_run(self):
        report = self.report()
        report["binary_replaced_during_run"] = True
        self.assertTrue(acceptance_failed(0, None, False, report))

    def test_process_and_artifact_failures_still_invalidate_run(self):
        for key, value in (("live_residual_pids", [123]),
                           ("artifact_verification_failure", "HashMismatch"),
                           ("metadata_hash_verified", False)):
            with self.subTest(key=key):
                report = self.report()
                report[key] = value
                self.assertTrue(acceptance_failed(0, None, False, report))
        self.assertTrue(acceptance_failed(1, None, False, self.report()))
        self.assertTrue(acceptance_failed(0, "Timeout", False, self.report()))
        self.assertTrue(acceptance_failed(0, None, True, self.report()))


if __name__ == "__main__":
    unittest.main()
