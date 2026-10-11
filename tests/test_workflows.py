import base64,importlib.util,json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('platform_runtime',ROOT/'scripts/platform.py')
runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)
class WorkflowTests(unittest.TestCase):
    def test_runner_groups_allow_only_protected_workflow_implementations(self):
        text=(ROOT/'infra/10-external/automation.tf').read_text()
        self.assertEqual(text.count('restricted_to_workflows = true'),2)
        for line in text.splitlines():
            if '/.github/workflows/' in line: self.assertIn('@refs/heads/main',line)
        for name in ('source-check','platform-check'):
            workflow=(ROOT/'.github/workflows'/(name+'.yml')).read_text()
            self.assertIn('on: [workflow_call]',workflow)
            self.assertIn('github.event.pull_request.head.repo.fork',workflow)
            self.assertIn("'fork-ci'",workflow)
            self.assertNotIn('secrets: inherit',workflow)
    def test_merged_onboarding_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp); template=path/'workflow.yml';template.write_text('desired')
            (path/'catalog.json').write_text(json.dumps({'organization':'org','repositories':{'repo':{'archived':False,'ci_profile':'source'}}}))
            (path/'config.json').write_text(json.dumps({'config':{}}))
            with patch.object(runtime,'gh',return_value={'content':base64.b64encode(b'desired').decode()}) as api:
                runtime.onboard(path/'catalog.json',path/'config.json',template)
                self.assertEqual(api.call_count,1)
    def test_no_workflow_uses_hosted_compute_or_artifact_uploads(self):
        for f in (ROOT/'.github/workflows').glob('*.yml'):
            text=f.read_text()
            self.assertNotIn('runs-on: ubuntu',text)
            self.assertNotIn('runs-on: windows',text)
            self.assertNotIn('upload-artifact',text)
if __name__=='__main__': unittest.main()
