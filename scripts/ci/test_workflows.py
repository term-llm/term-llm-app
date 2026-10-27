"""Guard the repository's self-hosted-only CI budget policy (no YAML dependency)."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class WorkflowBudgetTests(unittest.TestCase):
    NATIVE_WORKFLOWS = {
        "native-notification-tests.yml": {
            "WebPushCryptoTests", "PushMessageTests", "PushCenterTests", "PushDeliveryStoreTests",
            "NotificationMetadataTests", "NativeNotificationLifecycleTests", "ActualProducerFixtureTests",
            "NotificationReviewRegressionTests", "BrowserLifecycleTests", "VoiceShortcutTests",
            "LinkedDevicesProtocolTests", "LinkedDevicesIdentityTests", "LinkedDevicesRuntimeTests",
            "LinkedDevicesDiagnosticsTests", "PeerTransportTests", "PeerNWLoopbackListenerTests", "ServerAddressTests",
        },
        "linked-devices-native.yml": {
            "LinkedDevicesProtocolTests", "LinkedDevicesIdentityTests", "LinkedDevicesRuntimeTests",
            "LinkedDevicesDiagnosticsTests", "PeerTransportTests", "PeerNWLoopbackListenerTests", "ServerAddressTests", "DirectNodeClientTests", "HubConnectionStoreTests", "BrowserLifecycleTests",
        },
    }

    def test_all_runner_declarations_are_explicitly_local(self):
        workflows = sorted((ROOT / ".github/workflows").glob("*.y*ml"))
        self.assertTrue(workflows)
        for workflow in workflows:
            with self.subTest(workflow=workflow.name):
                text = workflow.read_text()
                runners = re.findall(r"^\s*runs-on:\s*(.+)$", text, re.MULTILINE)
                self.assertTrue(runners, "Each workflow must declare its local runner")
                for runner in runners:
                    self.assertEqual(runner, "[self-hosted, macOS, ARM64, term-llm-local]",
                                     "No hosted runners or dynamic fallback allowed")
                self.assertNotRegex(text, r"uses:\s*actions/(?:upload-artifact|cache|setup-go)@",
                                    "Do not introduce GitHub artifact/cache storage")

    def test_native_workflows_create_boot_and_clean_only_their_owned_simulator(self):
        for filename in self.NATIVE_WORKFLOWS:
            workflow = ROOT / ".github/workflows" / filename
            text = workflow.read_text()
            with self.subTest(workflow=filename):
                self.assertIn("term-llm-ci-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${GITHUB_JOB}", text)
                self.assertEqual(text.count("owned-ios-simulator.py create"), 1)
                self.assertEqual(text.count("owned-ios-simulator.py cleanup"), 1)
                self.assertNotIn("select-ios-simulator.py", text)
                cleanup = text.index("owned-ios-simulator.py cleanup")
                self.assertIn("if: always()", text[:cleanup].rsplit("- name:", 1)[-1])
                self.assertLess(cleanup, text.index("rm -rf -- \"$NATIVE_TEST_DIR\""))
                self.assertIn('--state-file "$NATIVE_TEST_DIR/owned-simulator.json"', text)

    def test_native_workflows_do_not_mutate_shared_inventory_or_retry_xcodebuild(self):
        helper = (ROOT / "scripts/ci/owned-ios-simulator.py").read_text()
        sources = [helper]
        for filename in self.NATIVE_WORKFLOWS:
            text = (ROOT / ".github/workflows" / filename).read_text()
            sources.append(text)
            with self.subTest(workflow=filename):
                self.assertEqual(len(re.findall(r"^\s*xcodebuild test \\$", text, re.MULTILINE)), 1,
                                 "Each native workflow gets one test attempt, never a blind full retry")
        combined = "\n".join(sources)
        self.assertNotRegex(combined, r"simctl\s+(?:shutdown|delete|erase)\s+(?:all|unavailable)\b")
        self.assertNotIn("--delete-unavailable", combined)

    def test_native_test_suite_selections_include_required_regressions(self):
        for filename, expected in self.NATIVE_WORKFLOWS.items():
            text = (ROOT / ".github/workflows" / filename).read_text()
            actual = set(re.findall(r"-only-testing:TermLLMTests/([A-Za-z0-9_]+)", text))
            with self.subTest(workflow=filename):
                self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
