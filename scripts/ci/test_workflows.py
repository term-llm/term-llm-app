"""Guard the repository's self-hosted-only CI budget policy (no YAML dependency)."""
import json
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"
TEST_PLANS = ROOT / "TestPlans"
LOCAL_RUNNER = "[self-hosted, macOS, ARM64, term-llm-local]"


def section(text, key):
    """A top-level YAML key with its indented lines."""
    match = re.search(rf"^{key}:.*\n(?:(?:[ #].*)?\n)*", text, re.MULTILINE)
    return match.group(0) if match else ""


def events(text):
    return set(re.findall(r"^  ([a-z_]+):", section(text, "on"), re.MULTILINE))


def jobs(text):
    parts = re.split(r"^  ([A-Za-z0-9_-]+):\s*$", section(text, "jobs"), flags=re.MULTILINE)
    return dict(zip(parts[1::2], parts[2::2]))


def workflows():
    return {path.name: path.read_text() for path in sorted(WORKFLOWS.glob("*.y*ml"))}


def test_plan(name):
    return json.loads((TEST_PLANS / f"{name}.xctestplan").read_text())


def test_case_classes():
    pattern = re.compile(r"^\s*(?:(?:final|public|internal|private|fileprivate|open)\s+)*class\s+(\w+)\s*:\s*XCTestCase\b",
                         re.MULTILINE)
    return {name for path in (ROOT / "TermLLMTests").rglob("*.swift") for name in pattern.findall(path.read_text())}


class WorkflowBudgetTests(unittest.TestCase):
    SIMULATOR_WORKFLOW = "native-simulator-tests.yml"
    # Manual entry points: display name and the TermLLM test plan their shared simulator job runs.
    NATIVE_ENTRY_POINTS = {
        "native-notification-tests.yml": ("Native notification checks (manual local Mac)", "TermLLM-Notifications"),
        "linked-devices-native.yml": ("Linked devices native validation", "TermLLM-LinkedDevices"),
        "native-unit-tests.yml": ("Native unit tests (manual local Mac)", "TermLLM-UnitTests"),
    }
    SELECTED_SUITES = {
        "TermLLM-Notifications": {
            "WebPushCryptoTests", "PushMessageTests", "PushCenterTests", "PushDeliveryStoreTests",
            "NotificationMetadataTests", "NativeNotificationLifecycleTests", "ActualProducerFixtureTests",
            "NotificationReviewRegressionTests", "BrowserLifecycleTests", "VoiceShortcutTests",
            "LinkedDevicesProtocolTests", "LinkedDevicesIdentityTests", "LinkedDevicesRuntimeTests",
            "LinkedDevicesDiagnosticsTests", "PeerTransportTests", "PeerNWLoopbackListenerTests", "LinkedDevicesLiveWebKitTests", "ServerAddressTests",
        },
        "TermLLM-LinkedDevices": {
            "LinkedDevicesProtocolTests", "LinkedDevicesIdentityTests", "LinkedDevicesRuntimeTests",
            "LinkedDevicesDiagnosticsTests", "PeerTransportTests", "PeerNWLoopbackListenerTests", "LinkedDevicesLiveWebKitTests", "ServerAddressTests", "DirectNodeClientTests", "HubConnectionStoreTests", "BrowserLifecycleTests",
        },
    }
    def test_all_runner_declarations_are_explicitly_local(self):
        self.assertTrue(workflows())
        for filename, text in workflows().items():
            with self.subTest(workflow=filename):
                for runner in re.findall(r"^\s*runs-on:\s*(.+)$", text, re.MULTILINE):
                    self.assertEqual(runner, LOCAL_RUNNER, "No hosted runners or dynamic fallback allowed")
                self.assertTrue(jobs(text))
                for job, block in jobs(text).items():
                    runners = re.findall(r"^    runs-on:\s*(.+)$", block, re.MULTILINE)
                    called = re.findall(r"^    uses:\s*(.+)$", block, re.MULTILINE)
                    if called:
                        # A reusable workflow's own jobs declare the runner; it must be one of ours.
                        self.assertEqual(runners, [], job)
                        self.assertEqual(len(called), 1, job)
                        self.assertRegex(called[0], r"^\./\.github/workflows/[a-z0-9-]+\.yml$",
                                         "Only call this repository's own reusable workflows")
                        self.assertTrue((ROOT / called[0]).is_file(), called[0])
                    else:
                        self.assertEqual(runners, [LOCAL_RUNNER], f"Job {job} must declare the local runner")
                self.assertNotRegex(text, r"uses:\s*actions/(?:upload-artifact|cache|setup-go)@",
                                    "Do not introduce GitHub artifact/cache storage")

    def test_only_lightweight_checks_and_main_releases_run_automatically(self):
        expected = {"checks.yml": {"pull_request", "workflow_dispatch"},
                    "notarized-mac-build.yml": {"push", "workflow_dispatch"},
                    self.SIMULATOR_WORKFLOW: {"workflow_call"}}
        for filename, text in workflows().items():
            with self.subTest(workflow=filename):
                self.assertEqual(events(text), expected.get(filename, {"workflow_dispatch"}),
                                 "Simulator and Mac test workflows are manual dispatch only")
        callers = {name for name, text in workflows().items()
                   if f"uses: ./.github/workflows/{self.SIMULATOR_WORKFLOW}" in text}
        self.assertEqual(callers, set(self.NATIVE_ENTRY_POINTS))

    def test_native_workflows_create_boot_and_clean_only_their_owned_simulator(self):
        creators = [name for name, text in workflows().items() if "owned-ios-simulator.py create" in text]
        self.assertEqual(creators, [self.SIMULATOR_WORKFLOW], "One shared job owns simulator setup and cleanup")
        text = (WORKFLOWS / self.SIMULATOR_WORKFLOW).read_text()
        self.assertIn("term-llm-ci-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${GITHUB_JOB}", text)
        self.assertEqual(text.count("owned-ios-simulator.py create"), 1)
        self.assertEqual(text.count("owned-ios-simulator.py cleanup"), 1)
        cleanup = text.index("owned-ios-simulator.py cleanup")
        self.assertIn("if: always()", text[:cleanup].rsplit("- name:", 1)[-1])
        self.assertLess(cleanup, text.index("rm -rf -- \"$NATIVE_TEST_DIR\""))
        self.assertIn('--state-file "$NATIVE_TEST_DIR/owned-simulator.json"', text)
        for filename, text in workflows().items():
            self.assertNotIn("select-ios-simulator.py", text, filename)

        for filename, (name, plan) in self.NATIVE_ENTRY_POINTS.items():
            text = (WORKFLOWS / filename).read_text()
            with self.subTest(workflow=filename):
                self.assertTrue(text.startswith(f"name: {name}\n"), "Docs and contracts refer to this name")
                (job, block), = jobs(text).items()
                self.assertEqual(re.findall(r"^    uses:\s*(.+)$", block, re.MULTILINE),
                                 [f"./.github/workflows/{self.SIMULATOR_WORKFLOW}"])
                self.assertIn(f"\n      test-plan: {plan}\n", block)
                for own in ("steps:", "secrets", "xcodebuild", "simctl"):
                    self.assertNotIn(own, text, "Entry points only choose a test plan")

    def test_native_workflows_do_not_mutate_shared_inventory_or_retry_xcodebuild(self):
        helper = (ROOT / "scripts/ci/owned-ios-simulator.py").read_text()
        for filename, text in workflows().items():
            with self.subTest(workflow=filename):
                attempts = len(re.findall(r"^\s*xcodebuild test \\$", text, re.MULTILINE))
                self.assertLessEqual(attempts, 1, "One test attempt per job, never a blind full retry")
                self.assertNotRegex(text, r"-retry-tests-on-failure|-test-iterations|-run-tests-until-failure")
                self.assertNotIn("-only-testing:TermLLMTests", text, "Suite selections live in TestPlans/")
        simulator = (WORKFLOWS / self.SIMULATOR_WORKFLOW).read_text()
        self.assertEqual(len(re.findall(r"^\s*xcodebuild test \\$", simulator, re.MULTILINE)), 1)
        self.assertIn('-testPlan "$TEST_PLAN"', simulator)
        self.assertIn("TEST_PLAN: ${{ inputs.test-plan }}", simulator)
        self.assertNotRegex(simulator.split("    steps:", 1)[1], r"\$\{\{\s*inputs\.",
                            "Inputs reach run scripts only through the environment")
        combined = "\n".join([helper, *workflows().values()])
        self.assertNotRegex(combined, r"simctl\s+(?:shutdown|delete|erase)\s+(?:all|unavailable)\b")
        self.assertNotIn("--delete-unavailable", combined)

    def test_notarized_mac_build_keeps_signing_secrets_in_trusted_main_steps(self):
        text = (ROOT / ".github/workflows/notarized-mac-build.yml").read_text()
        triggers = text.split("\npermissions:", 1)[0]
        self.assertNotIn("pull_request", triggers, "Signing secrets must never run for pull requests")
        self.assertIn("branches: [main]", triggers)
        for path in ("'TermLLMMac/**'", "'scripts/ci/**'", "'TermLLMComputerUse/**'", "'ComputerUseKit/**'"):
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
        for name in ("Fetch SHA-256 pinned Sparkle 2.10.1 signing tools", "Archive and export with Developer ID signing", "Sign and publish Sparkle archive and appcast"):
            self.assertNotIn("env:", steps[name])
            self.assertNotIn("OP_SERVICE_ACCOUNT_TOKEN", steps[name])
        order = list(steps)
        self.assertLess(order.index("Fetch SHA-256 pinned Sparkle 2.10.1 signing tools"), order.index("Install Developer ID profiles and import the identity into a RAM-disk keychain"))
        self.assertLess(order.index("Notarize and staple"), order.index("Sign and publish Sparkle archive and appcast"))
        self.assertLess(order.index("Sign and publish Sparkle archive and appcast"), order.index("Publish the notarized app as a GitHub release"))
        self.assertIn("cancel-in-progress: false", text)
        archive = steps["Archive and export with Developer ID signing"]
        self.assertIn("SWIFT_ACTIVE_COMPILATION_CONDITIONS=", archive)
        self.assertIn("OTHER_SWIFT_FLAGS=", archive)
        for setting in ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "OTHER_SWIFT_FLAGS"):
            line, = [line.strip() for line in archive.splitlines() if line.strip().startswith(setting + "=")]
            self.assertEqual(line.removesuffix(chr(92)).rstrip(), setting + "=",
                             "Archive overrides must clear inherited local-test compiler conditions")
        self.assertNotIn("SPARKLE_LOCAL_FEED_TEST", archive)

        helper = (ROOT / "scripts/ci/notarized-mac-build.py").read_text()
        names = re.search(r"SECRET_NAMES = \((.*?)\)", helper, re.S).group(1)
        references = dict(re.findall(r"^      ([A-Z0-9_]+)_REF: '(op://[^']+)'$", text, re.M))
        self.assertEqual(set(references), set(re.findall(r'"([A-Z0-9_]+)"', names)))
        for reference in references.values():
            self.assertTrue(reference.startswith("op://term-llm CI/"), reference)
            self.assertRegex(reference, r"^op://[A-Za-z0-9 ._-]+(?:/[A-Za-z0-9 ._-]+){2,3}$",
                             "1Password references only allow alphanumerics, space, '.', '_' and '-'")

        self.assertIn("select-version", steps["Select the next Mac patch version"])
        self.assertNotIn("OP_SERVICE_ACCOUNT_TOKEN", steps["Select the next Mac patch version"])
        self.assertEqual(text.count("contents: write"), 1)
        self.assertEqual(text.count("github.token"), 2)
        self.assertIn("GH_TOKEN: ${{ github.token }}", steps["Publish the notarized app as a GitHub release"])

        self.assertIn('WORK_PREFIX = "term-llm-mac-release."', helper)
        self.assertIn('"$RUNNER_TEMP/term-llm-mac-release.XXXXXX"', text)
        cleanup = steps["Remove the job keychain, RAM disk, profiles and build files"]
        self.assertIn("if: always()", cleanup)
        self.assertIn('notarized-mac-build.py --work-dir "$MAC_RELEASE_DIR" cleanup', cleanup)
        self.assertEqual(list(steps)[-1], "Remove the job keychain, RAM disk, profiles and build files")

    def test_native_test_suite_selections_include_required_regressions(self):
        suites = test_case_classes()
        for plan, expected in self.SELECTED_SUITES.items():
            with self.subTest(test_plan=plan):
                entries = test_plan(plan)["testTargets"]
                self.assertEqual([entry["target"]["name"] for entry in entries], ["TermLLMTests"])
                selected = entries[0]["selectedTests"]
                self.assertEqual(len(selected), len(set(selected)))
                self.assertEqual(set(selected), expected)
                self.assertNotIn("skippedTests", entries[0])
                self.assertLessEqual(expected, suites, "A selected suite no longer exists in TermLLMTests/")

    def test_termllm_scheme_runs_only_checked_in_test_plans(self):
        action = ET.parse(ROOT / "TermLLM.xcodeproj/xcshareddata/xcschemes/TermLLM.xcscheme").getroot().find("TestAction")
        self.assertIsNone(action.find("Testables"), "Test plans, not scheme testables, choose the tests")
        references = {ref.get("reference"): ref.get("default") for ref in action.iter("TestPlanReference")}
        plans = {path.stem for path in TEST_PLANS.glob("*.xctestplan")}
        self.assertEqual(set(references), {f"container:TestPlans/{name}.xctestplan" for name in plans})
        self.assertEqual([ref for ref, default in references.items() if default == "YES"],
                         ["container:TestPlans/TermLLM.xctestplan"])
        self.assertLessEqual({plan for _, plan in self.NATIVE_ENTRY_POINTS.values()}, plans)

        project = (ROOT / "TermLLM.xcodeproj/project.pbxproj").read_text()
        targets = dict(re.findall(r"^\t\t([0-9A-F]{24}) /\* (\w+) \*/ = \{\n\t\t\tisa = PBXNativeTarget;", project, re.M))
        for name in plans:
            with self.subTest(test_plan=name):
                data = test_plan(name)
                # One configuration (one run per dispatch) and no options: plans only choose tests.
                self.assertEqual([config["options"] for config in data["configurations"]], [{}])
                self.assertEqual(set(data["defaultOptions"]), {"targetForVariableExpansion"})
                for target in [data["defaultOptions"]["targetForVariableExpansion"],
                               *(entry["target"] for entry in data["testTargets"])]:
                    self.assertEqual(target["containerPath"], "container:TermLLM.xcodeproj")
                    self.assertEqual(targets.get(target["identifier"]), target["name"])
                self.assertTrue(all(set(entry) <= {"target", "selectedTests"} for entry in data["testTargets"]))
        # The default plan is the scheme's former testables; the all-unit plan is every TermLLMTests suite.
        for name, bundles in {"TermLLM": ["TermLLMTests", "TermLLMUITests"], "TermLLM-UnitTests": ["TermLLMTests"]}.items():
            with self.subTest(test_plan=name):
                entries = test_plan(name)["testTargets"]
                self.assertEqual([entry["target"]["name"] for entry in entries], bundles)
                self.assertTrue(all(set(entry) == {"target"} for entry in entries), "No selection or skips")


if __name__ == "__main__":
    unittest.main()
