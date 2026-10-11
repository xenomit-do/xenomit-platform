import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("platform_runtime", ROOT / "scripts/platform.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class PublicationTests(unittest.TestCase):
    def test_public_repo_does_not_require_attestation(self):
        runtime.audit_private('repo', {'private': False}, {})

    def test_private_repo_needs_current_review_and_scan(self):
        remote = {'private': True, 'default_branch': 'main'}
        with patch.object(runtime, 'gh', return_value={'sha': 'current'}):
            for audit in [None, {'github_head':'old','reviewed_private_data':True,'secret_scan_passed':True},
                          {'github_head':'current','reviewed_private_data':True,'secret_scan_passed':False}]:
                c = {'publication_audits': {'repo':audit} if audit else {}}
                with self.assertRaises(runtime.Failure):
                    runtime.audit_private('repo', remote, c)
            runtime.audit_private('repo', remote, {'publication_audits': {'repo': {
                'github_head':'current','reviewed_private_data':True,'secret_scan_passed':True}}})


class RecoveryTests(unittest.TestCase):
    def test_import_skips_existing_addresses(self):
        known = {'github_repository.managed["repo"]'}
        with patch.object(runtime, 'run') as run:
            runtime.import_one('/stack','/vars',known,'github_repository.managed["repo"]','repo')
            run.assert_not_called()

    def test_import_adds_address_only_after_success(self):
        known = set()
        with patch.object(runtime, 'run', side_effect=runtime.Failure('provider error')):
            with self.assertRaises(runtime.Failure):
                runtime.import_one('/stack','/vars',known,'resource.repo','repo')
        self.assertEqual(known, set())
        with patch.object(runtime, 'run') as run:
            runtime.import_one('/stack','/vars',known,'resource.repo','repo')
            self.assertIn('resource.repo', known)
            self.assertIn('-lock-timeout=5m',run.call_args.args[0])

    def test_owner_collision_blocks_second_machine(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp)/'config.json'; owner = Path(temp)/'owner'
            config.write_text(json.dumps({'config':{'environment_id':'laptop'}}))
            owner.write_text('this-machine')
            with patch.object(runtime,'gh',return_value={'value':'other-machine'}):
                with self.assertRaises(runtime.Failure):
                    runtime.lease(str(config),str(owner))

    def test_owner_reentry_does_not_recreate_claim(self):
        with tempfile.TemporaryDirectory() as temp:
            config=Path(temp)/'config.json'; owner=Path(temp)/'owner'
            config.write_text(json.dumps({'config':{'environment_id':'laptop'}})); owner.write_text('mine')
            with patch.object(runtime,'gh',return_value={'value':'mine'}) as gh:
                runtime.lease(str(config),str(owner))
                self.assertEqual(gh.call_count,1)

    def test_pagination_reads_all_repositories(self):
        with patch.object(runtime,'gh',side_effect=[[{'name':str(i)} for i in range(100)], [{'name':'last'}]]):
            self.assertEqual(len(runtime.pages('/orgs/org/repos',{})),101)


class WorkspaceTests(unittest.TestCase):
    def test_dirty_checkout_is_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); checkout=root/'repo'; checkout.mkdir(); (checkout/'.git').mkdir()
            catalog=root/'catalog.json'; output=root/'revision.json'
            catalog.write_text(json.dumps({'organization':'org','repositories':{'repo':{'workspace':True,'default_branch':'main'}}}))
            def command(args,**kwargs):
                if args[1]=='ls-remote': return 'remote-sha refs/heads/main'
                if args[1]=='remote': return 'https://github.com/org/repo.git'
                if args[1]=='status': return ' M local.txt'
                if args[1]=='rev-parse': return 'local-sha'
                self.fail('Unexpected mutation: '+repr(args))
            with patch.object(runtime,'run',side_effect=command):
                runtime.workspace(str(catalog),str(root),str(output))
            report=json.loads(output.read_text())
            self.assertEqual(report['repositories']['repo'],'remote-sha')
            self.assertEqual(report['local_checkouts']['repo'],'local-sha')


class ConfigurationTests(unittest.TestCase):
    def test_distinct_backend_keys(self):
        keys=[]
        for path in (ROOT/'infra').glob('*/versions.tf'):
            text=path.read_text()
            import re
            keys.append(re.search(r'secret_suffix\s*=\s*"([^"]+)"',text).group(1))
        self.assertEqual(len(keys),len(set(keys)))

    def test_all_active_repositories_have_required_checks(self):
        catalog=json.loads((ROOT/'repositories.json').read_text())
        for name,repo in catalog['repositories'].items():
            if not repo['archived']:
                self.assertTrue(repo['required_checks'],name)


if __name__=='__main__': unittest.main()
