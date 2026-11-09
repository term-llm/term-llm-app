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
            "LinkedDevicesDiagnosticsTests", "PeerTransportTests", "PeerNWLoopbackListenerTests", "LinkedDevicesLiveWebKitTests", "ServerAddressTests",
        },
        "linked-devices-native.yml": {
            "LinkedDevicesProtocolTests", "LinkedDevicesIdentityTests", "LinkedDevicesRuntimeTests",
            "LinkedDevicesDiagnosticsTests", "PeerTransportTests", "PeerNWLoopbackListenerTests", "LinkedDevicesLiveWebKitTests", "ServerAddressTests", "DirectNodeClientTests", "HubConnectionStoreTests", "BrowserLifecycleTests",
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

    def test_notarized_mac_build_keeps_signing_secrets_in_trusted_main_steps(self):
        text = (ROOT / ".github/workflows/notarized-mac-build.yml").read_text()
        triggers = text.split("\npermissions:", 1)[0]
        self.assertNotIn("pull_request", triggers, "Signing secrets must never run for pull requests")
        self.assertIn("branches: [main]", triggers)
        for path in ("'TermLLMMac/**'", "'scripts/ci/notarized-mac-build.py'"):
            self.assertIn(path, triggers)
        self.assertIn("if: github.ref == 'refs/heads/main'", text)
        self.assertIn("persist-credentials: false", text)

        steps = {block.split("\n", 1)[0].strip(): block for block in text.split("\n      - name: ")[1:]}
        used = {name: set(re.findall(r"secrets\.([A-Z0-9_]+)", block)) for name, block in steps.items()}
        token = {"OP_SERVICE_ACCOUNT_TOKEN"}
        self.assertEqual({name: secrets for name, secrets in used.items() if secrets}, {
            "Require the 1Password service account token and CLI": token,
            "Install Developer ID profiles and import the identity into a RAM-disk keychain": token,
            "Stage the notary key on the RAM disk": token,
        }, "Signing material comes from 1Password; GitHub only holds the service account token")
        presence = steps["Require the 1Password service account token and CLI"]
        self.assertEqual(re.findall(r"secrets\.[A-Z0-9_]+ != ''", presence), ["secrets.OP_SERVICE_ACCOUNT_TOKEN != ''"],
                         "The presence check must only receive a boolean")
        # The runner writes run scripts to disk, so the token may only arrive as a step env value.
        for line in text.splitlines():
            if "secrets." in line:
                self.assertRegex(line, r"^\s+(OP_SERVICE_ACCOUNT_TOKEN): \$\{\{ secrets\.\1(?: != '')? \}\}$")
        self.assertIn("stage-notary-key", steps["Stage the notary key on the RAM disk"])
        self.assertNotIn("env:", steps["Notarize and staple"], "The long notary wait must not hold secrets")

        helper = (ROOT / "scripts/ci/notarized-mac-build.py").read_text()
        names = re.search(r"SECRET_NAMES = \((.*?)\)", helper, re.S).group(1)
        references = dict(re.findall(r"^      ([A-Z0-9_]+)_REF: '(op://[^']+)'$", text, re.M))
        self.assertEqual(set(references), set(re.findall(r'"([A-Z0-9_]+)"', names)))
        for reference in references.values():
            self.assertTrue(reference.startswith("op://term-llm CI/"), reference)
            self.assertRegex(reference, r"^op://[A-Za-z0-9 ._-]+(?:/[A-Za-z0-9 ._-]+){2,3}$",
                             "1Password references only allow alphanumerics, space, '.', '_' and '-'")

        self.assertEqual(text.count("contents: write"), 1)
        self.assertEqual(text.count("github.token"), 1)
        self.assertIn("GH_TOKEN: ${{ github.token }}", steps["Publish the notarized app as a GitHub release"])

        self.assertIn('WORK_PREFIX = "term-llm-mac-release."', helper)
        self.assertIn('"$RUNNER_TEMP/term-llm-mac-release.XXXXXX"', text)
        cleanup = steps["Remove the job keychain, RAM disk, profiles and build files"]
        self.assertIn("if: always()", cleanup)
        self.assertIn('notarized-mac-build.py --work-dir "$MAC_RELEASE_DIR" cleanup', cleanup)
        self.assertEqual(list(steps)[-1], "Remove the job keychain, RAM disk, profiles and build files")

    def test_native_test_suite_selections_include_required_regressions(self):
        for filename, expected in self.NATIVE_WORKFLOWS.items():
            text = (ROOT / ".github/workflows" / filename).read_text()
            actual = set(re.findall(r"-only-testing:TermLLMTests/([A-Za-z0-9_]+)", text))
            with self.subTest(workflow=filename):
                self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
