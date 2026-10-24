"""Guard the repository's self-hosted-only CI budget policy (no YAML dependency)."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class WorkflowBudgetTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
