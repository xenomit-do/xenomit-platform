#!/usr/bin/env python3
"""Bootstrap/recovery helpers. Only stdlib; credentials never enter command arguments."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


class Failure(Exception):
    pass


def run(args, *, capture=True, cwd=None, check=True, input=None):
    environment = os.environ.copy()
    environment['GIT_TERMINAL_PROMPT'] = '0'
    p = subprocess.run(args, cwd=cwd, input=input, text=True, env=environment,
                       stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.PIPE if capture else None)
    if check and p.returncode:
        # Do not echo stderr from providers/API clients: it may contain secrets.
        raise Failure(f'{args[0]} failed (exit {p.returncode}); rerun the documented operation locally for diagnostics')
    return p.stdout.strip() if capture else p.returncode


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value, indent=2) + '\n')
    p.chmod(0o600)


def api(base, path, token, method='GET', data=None, optional=False):
    req = urllib.request.Request(base + path, method=method,
          headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/json',
                   'Content-Type': 'application/json', 'User-Agent': 'xenomit-platform'},
          data=json.dumps(data).encode() if data is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=45) as response:
            content = response.read()
            return json.loads(content) if content else None
    except urllib.error.HTTPError as error:
        if optional and error.code == 404:
            return None
        raise Failure(f'{method} {path.split("?")[0]} returned HTTP {error.code}') from None


def gh(path, config, **kwargs):
    return api('https://api.github.com', path, config['github_admin_token'], **kwargs)


def cf(path, config, **kwargs):
    result = api('https://api.cloudflare.com/client/v4', path, config['cloudflare_token'], **kwargs)
    if not result['success']:
        raise Failure('Cloudflare API rejected ' + path.split('?')[0])
    return result['result']


def pages(path, config):
    output = []
    for page in range(1, 1000):
        result = gh(f'{path}{"&" if "?" in path else "?"}per_page=100&page={page}', config)
        output.extend(result)
        if len(result) < 100:
            return output
    raise Failure('Pagination exceeded safety limit')


def prepare(source, destination):
    c = read(source)
    unresolved = [key for key, value in c.items() if 'REPLACE' in json.dumps(value)]
    if c['domain'] == 'example.com':
        unresolved.append('domain')
    if unresolved:
        raise Failure('Unresolved bootstrap configuration fields: ' + ', '.join(sorted(set(unresolved))))
    for field in ('cluster_name', 'environment_id', 'maintainer_team'):
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,49}', c[field]):
            raise Failure(f'Invalid {field}')
    if not re.fullmatch(r'[a-z0-9.-]+\.[a-z]{2,}', c['domain']):
        raise Failure('Invalid domain')
    for stem in ('github_admin_token', 'cloudflare_token', 'atlantis_app_key', 'arc_app_key'):
        p = Path(c.pop(stem + '_file')).expanduser()
        if p.stat().st_mode & 0o077:
            raise Failure(f'{p.name} must have mode 600 (chmod 600)')
        c[stem] = p.read_text().strip()
        if not c[stem]:
            raise Failure(f'{p.name} is empty')
    if c.get('deployment_token_file'):
        token_path = Path(c.pop('deployment_token_file')).expanduser()
        if token_path.stat().st_mode & 0o077:
            raise Failure('deployment token must have mode 600')
        c['deployment_token'] = token_path.read_text().strip()
    audit_path = Path(c.pop('publication_audits_file')).expanduser()
    c['publication_audits'] = read(audit_path) if audit_path.exists() else {}
    c['maintainer_ids'] = [gh('/users/' + urllib.parse.quote(u, safe=''), c)['id'] for u in c['maintainers']]
    if not c['maintainer_ids']:
        raise Failure('At least one maintainer is required for public fork approval')
    write(destination, {'config': c})


def git_refs(path):
    refs = run(['git', 'for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads', 'refs/tags'], cwd=path)
    return hashlib.sha256(refs.encode()).hexdigest()


def workspace(catalog_path, directory, output):
    catalog = read(catalog_path)
    org = catalog['organization']
    revisions = {'organization': org, 'repositories': {}, 'local_checkouts': {}}
    for name, repo in catalog['repositories'].items():
        if not repo['workspace']:
            continue
        target = Path(directory) / name
        url = f'https://github.com/{org}/{name}.git'
        branch = repo['default_branch']
        refs = run(['git', 'ls-remote', '--exit-code', url, 'refs/heads/' + branch], check=False)
        if not refs:
            # Repo creation happens in external apply; clone once it exists.
            revisions['repositories'][name] = None
            print(f'{name}: GitHub branch unavailable; import/publish it before verification', file=sys.stderr)
            continue
        sha = refs.split()[0]
        revisions['repositories'][name] = sha
        if not target.exists():
            run(['git', 'clone', '--branch', branch, url, str(target)], capture=False)
        elif not (target / '.git').exists():
            print(f'{name}: source-only directory preserved; migrate it through the repository onboarding runbook', file=sys.stderr)
            revisions['local_checkouts'][name] = None
            continue
        if not run(['git', 'rev-parse', '--verify', 'HEAD'], cwd=target, check=False):
            print(f'{name}: unborn Git checkout preserved; import its source through onboarding', file=sys.stderr)
            revisions['local_checkouts'][name] = None
            continue
        origin = run(['git', 'remote', 'get-url', 'origin'], cwd=target, check=False)
        if origin not in (url, url[:-4], f'git@github.com:{org}/{name}.git'):
            print(f'{name}: origin differs; checkout unchanged, see migration runbook', file=sys.stderr)
        elif run(['git', 'status', '--porcelain'], cwd=target):
            print(f'{name}: dirty checkout preserved', file=sys.stderr)
        else:
            run(['git', 'fetch', 'origin', branch], cwd=target)
            head = run(['git', 'rev-parse', 'HEAD'], cwd=target)
            current = run(['git', 'branch', '--show-current'], cwd=target)
            ancestor = subprocess.run(['git', 'merge-base', '--is-ancestor', head, sha], cwd=target,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if current == branch and ancestor:
                run(['git', 'merge', '--ff-only', sha], cwd=target)
            elif head != sha:
                print(f'{name}: non-default/divergent checkout preserved', file=sys.stderr)
        revisions['local_checkouts'][name] = run(['git', 'rev-parse', 'HEAD'], cwd=target)
    write(output, revisions)


def kube_json(args):
    return json.loads(run(['kubectl', *args, '-o', 'json']))


def lease(config_path, owner_path):
    c = read(config_path)['config']
    owner_file = Path(owner_path)
    if not owner_file.exists():
        owner_file.write_text(secrets.token_hex(16))
        owner_file.chmod(0o600)
    owner = owner_file.read_text().strip()
    # One organization-wide claim prevents parallel environments sharing repository policy and DNS.
    org = 'xenomit-do'
    key = 'XENOMIT_ACTIVE_ENVIRONMENT'
    existing = gh(f'/repos/{org}/xenomit-platform/actions/variables/{key}', c, optional=True)
    if existing and existing['value'] != owner:
        raise Failure('Environment owned by another workspace. Stop it and follow machine-migration runbook before transferring ownership')
    if not existing:
        gh(f'/repos/{org}/xenomit-platform/actions/variables', c, method='POST', data={'name': key, 'value': owner})


def state_addresses(stack):
    return set(run(['tofu', '-chdir=' + stack, 'state', 'list']).splitlines())


def import_one(stack, config_path, known, address, identifier):
    if address not in known:
        run(['tofu', '-chdir=' + stack, 'import', '-input=false', '-lock-timeout=5m',
             '-var-file=' + config_path, address, str(identifier)], capture=False)
        known.add(address)


def import_identity(stack, config_path):
    known = state_addresses(stack)
    namespaces = kube_json(['get', 'namespaces'])
    wanted = {'argocd', 'ci', 'arc-system', 'arc-build', 'arc-platform', 'xenomit-system',
              'xenomit-bots', 'xenomit-data', 'observability', 'kyverno'}
    for ns in namespaces['items']:
        name = ns['metadata']['name']
        if name in wanted:
            import_one(stack, config_path, known, f'kubernetes_namespace_v1.managed["{name}"]', name)
    secrets_list = kube_json(['get', 'secrets', '-A'])['items']
    # Existing random resources must stay in state; importing a Secret alone would rotate passwords.
    for secret in secrets_list:
        meta = secret['metadata']
        if meta['name'] == 'platform-credentials' and 'random_password.webhook' not in known:
            raise Failure('Identity state lost while credential Secret survives. Restore its state; do not reset live credentials')


def import_vault(stack, config_path):
    import base64, urllib.request
    known = state_addresses(stack)
    secret = kube_json(['get', 'secret', 'vault-admin', '-n', 'xenomit-system'])
    token = base64.b64decode(secret['data']['token']).decode()
    address = os.environ.get('TF_VAR_vault_address', 'http://vault.xenomit-system.svc.cluster.local:8200')
    request = urllib.request.Request(address + '/v1/sys/auth', headers={'X-Vault-Token': token})
    with urllib.request.urlopen(request) as response:
        mounts = json.load(response)['data']
    if 'jwt/' in mounts and 'vault_jwt_auth_backend.jwt' not in known:
        # A failed provider create can leave an unconfigured mount. Complete
        # its Git-defined configuration so provider Read can import it.
        config = read(config_path)['config']
        body = json.dumps({'jwt_validation_pubkeys': config['jwt_validation_pubkeys'],
                           'bound_issuer': config['jwt_issuer']}).encode()
        request = urllib.request.Request(address + '/v1/auth/jwt/config', data=body,
            headers={'X-Vault-Token': token, 'Content-Type': 'application/json'}, method='PUT')
        with urllib.request.urlopen(request):
            pass
        import_one(stack, config_path, known, 'vault_jwt_auth_backend.jwt', 'jwt')


def audit_private(name, remote, c):
    if remote is None or not remote['private']:
        return
    audit = c['publication_audits'].get(name)
    branch = remote['default_branch']
    head = gh(f'/repos/xenomit-do/{name}/commits/{branch}', c)['sha']
    if not audit or not audit.get('reviewed_private_data') or not audit.get('secret_scan_passed') or audit.get('github_head') != head:
        raise Failure(f'{name}: private publication requires a current secret scan and human private-data review; see migration.md')


def import_external(stack, config_path, catalog_path):
    c = read(config_path)['config']
    catalog = read(catalog_path)
    org = catalog['organization']
    known = state_addresses(stack)
    unknown = [r['name'] for r in pages('/orgs/xenomit-do/repos?type=all', c) if r['name'] not in catalog['repositories']]
    if unknown:
        raise Failure('Register all organization repositories before apply: ' + ', '.join(unknown))
    for name, definition in catalog['repositories'].items():
        repo = gh(f'/repos/{org}/{name}', c, optional=True)
        audit_private(name, repo, c)
        if repo is None:
            continue
        import_one(stack, config_path, known, f'github_repository.managed["{name}"]', name)
        if repo['size'] > 0:
            import_one(stack, config_path, known, f'github_branch_default.managed["{name}"]', name)
        try:
            protections = gh(f'/repos/{org}/{name}/branches/{definition["default_branch"]}/protection', c, optional=True)
        except Failure as error:
            # GitHub Free rejects this endpoint for private repositories. The
            # following apply publishes audited repositories before protection.
            if repo['private'] and str(error).endswith('returned HTTP 403'):
                protections = None
            else:
                raise
        if protections:
            import_one(stack, config_path, known, f'github_branch_protection.managed["{name}"]', f'{name}:{definition["default_branch"]}')
        if definition['atlantis']:
            hooks = pages(f'/repos/{org}/{name}/hooks', c)
            matching = [h for h in hooks if h['config'].get('url') == f'https://atlantis.{c["domain"]}/events']
            if len(matching) > 1:
                raise Failure(f'{name}: duplicate Atlantis hooks; resolve before importing')
            if matching:
                import_one(stack, config_path, known, f'github_repository_webhook.atlantis["{name}"]', f'{name}/{matching[0]["id"]}')
    environment = gh('/repos/xenomit-do/xenomit-platform/environments/platform-admin', c, optional=True)
    if environment:
        import_one(stack, config_path, known, 'github_repository_environment.platform_admin', 'xenomit-platform:platform-admin')
    if gh('/repos/xenomit-do/xenomit-platform/environments/platform-release', c, optional=True):
        import_one(stack, config_path, known, 'github_repository_environment.platform_release', 'xenomit-platform:platform-release')
    for group in gh('/orgs/xenomit-do/actions/runner-groups', c)['runner_groups']:
        if group['name'] in ('xenomit-build', 'xenomit-platform'):
            label = group['name'].removeprefix('xenomit-')
            import_one(stack, config_path, known, 'github_actions_runner_group.' + label, group['id'])
    team = gh(f'/orgs/{org}/teams/{c["maintainer_team"]}', c, optional=True)
    import_one(stack, config_path, known, 'github_organization_settings.managed', org)
    for name, definition in catalog['repositories'].items():
        if not definition['archived'] and gh(f'/repos/{org}/{name}/environments/fork-ci', c, optional=True):
            import_one(stack, config_path, known, f'github_repository_environment.fork_ci["{name}"]', f'{name}:fork-ci')
    if team:
        import_one(stack, config_path, known, 'github_team.maintainers', team['id'])
        members = pages(f'/orgs/{org}/teams/{team["slug"]}/members', c)
        for member in members:
            if member['login'] in c['maintainers']:
                import_one(stack, config_path, known, f'github_team_membership.maintainers["{member["login"]}"]', f'{team["id"]}:{member["login"]}')
        for repo in pages(f'/orgs/{org}/teams/{team["slug"]}/repos', c):
            if repo['name'] in catalog['repositories']:
                import_one(stack, config_path, known, f'github_team_repository.maintainers["{repo["name"]}"]', f'{team["id"]}:{repo["name"]}')
    account, zone = c['cloudflare_account_id'], c['cloudflare_zone_id']
    name = 'xenomit-' + c['environment_id'] + '-atlantis'
    existing_id = c.get('existing_tunnel_id')
    if existing_id:
        if not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', existing_id):
            raise Failure('existing_tunnel_id must be a Cloudflare tunnel UUID')
        tunnel = cf(f'/accounts/{account}/cfd_tunnel/{existing_id}', c)
        if tunnel.get('deleted_at'):
            raise Failure('The explicitly selected Cloudflare tunnel has been deleted')
        tunnels = [tunnel]
    else:
        tunnels = cf(f'/accounts/{account}/cfd_tunnel?is_deleted=false&name={urllib.parse.quote(name)}', c)
    if len(tunnels) > 1:
        raise Failure('Multiple tunnels match environment; import is ambiguous')
    if tunnels:
        ident = tunnels[0]['id']
        import_one(stack, config_path, known, 'cloudflare_zero_trust_tunnel_cloudflared.atlantis', f'{account}/{ident}')
        existing_config = cf(f'/accounts/{account}/cfd_tunnel/{ident}/configurations', c)
        # A newly created dashboard tunnel has no ingress configuration yet.
        # Importing that missing configuration crashes Cloudflare provider v4.
        if existing_config and (existing_config.get('config') or {}).get('ingress'):
            import_one(stack, config_path, known, 'cloudflare_zero_trust_tunnel_cloudflared_config.atlantis', f'{account}/{ident}')
    records = cf(f'/zones/{zone}/dns_records?type=CNAME&name=atlantis.{c["domain"]}', c)
    if len(records) > 1:
        raise Failure('Multiple DNS records match tunnel hostname')
    if records:
        import_one(stack, config_path, known, 'cloudflare_record.atlantis', f'{zone}/{records[0]["id"]}')


def inventory(catalog_path, directory, output):
    result = {}
    for name in read(catalog_path)['repositories']:
        path = Path(directory) / name
        if not (path / '.git').exists():
            result[name] = {'state': 'source_without_git_history' if path.exists() else 'missing_local_checkout'}
            continue
        if (path / '.git').exists():
            result[name] = {
                'head': run(['git', 'rev-parse', 'HEAD'], cwd=path),
                'refs': run(['git', 'for-each-ref', '--format=%(refname) %(objectname)'], cwd=path).splitlines(),
                'changes': run(['git', 'status', '--porcelain'], cwd=path).splitlines(),
                # Do not capture remote URLs; legacy URLs can embed tokens.
                'refs_digest': git_refs(path),
            }
    write(output, result)


def verify(catalog_path, config_path):
    c = read(config_path)['config']
    catalog = read(catalog_path)
    failures = []
    live = pages('/orgs/' + catalog['organization'] + '/repos?type=all', c)
    for repo in live:
        name = repo['name']
        repo = gh(f'/repos/{catalog["organization"]}/{name}', c)
        definition = catalog['repositories'].get(name)
        if definition is None:
            failures.append(f'{name}: missing from catalog')
            continue
        if repo['private']:
            failures.append(f'{name}: not public')
        if not repo['delete_branch_on_merge']:
            failures.append(f'{name}: deletion after merge disabled')
        if repo['default_branch'] != definition['default_branch']:
            failures.append(f'{name}: default branch differs')
        if not repo['archived']:
            p = gh(f'/repos/{catalog["organization"]}/{name}/branches/{definition["default_branch"]}/protection', c, optional=True)
            if p and p.get('required_pull_request_reviews', {}).get('required_approving_review_count') != 0:
                failures.append(f'{name}: mandatory human approval count differs')
            checks = set(definition['required_checks']) | ({'atlantis/plan', 'atlantis/apply'} if definition['atlantis'] else set())
            if not p or not p.get('required_pull_request_reviews') or not p.get('enforce_admins', {}).get('enabled'):
                failures.append(f'{name}: PR/admin protection incomplete')
            elif (not p.get('required_conversation_resolution', {}).get('enabled') or
                  p.get('allow_deletions', {}).get('enabled') or p.get('allow_force_pushes', {}).get('enabled')):
                failures.append(f'{name}: conversation/deletion/force-push policy differs')
            if checks and (not p or not p.get('required_status_checks', {}).get('strict') or
                           not checks.issubset(set(p.get('required_status_checks', {}).get('contexts', [])))):
                failures.append(f'{name}: required checks incomplete')
    for name, definition in catalog['repositories'].items():
        if definition['archived'] or name not in {r['name'] for r in live}:
            continue
        base = f'/repos/{catalog["organization"]}/{name}'
        workflow_files = gh(base + '/contents/.github/workflows', c, optional=True) or []
        if definition['ci_profile'] == 'source' and not any(f['name'] == 'source-check.yml' for f in workflow_files):
            failures.append(f'{name}: shared source-check workflow not merged; see onboarding PR')
        for workflow in workflow_files:
            if workflow['type'] != 'file' or not workflow['name'].endswith(('.yml', '.yaml')):
                continue
            body = gh(base + '/contents/' + workflow['path'], c)
            text = base64.b64decode(body['content']).decode()
            if re.search(r'runs-on:[^\n]*(?:ubuntu-|windows-|macos-)', text):
                failures.append(f'{name}/{workflow["name"]}: GitHub-hosted runner remains; migrate or disable this workflow')
    names = {r['name'] for r in live}
    failures.extend(f'{name}: missing from GitHub' for name in catalog['repositories'] if name not in names)
    apps = kube_json(['get', 'applications.argoproj.io', '-n', 'argocd'])['items']
    expected = {'xenomit-build-runners', 'xenomit-platform-runners', 'xenomit-bots'}
    if c['enable_applications']:
        expected |= {'xenomit-control-plane', 'xenomit-panel'}
    by_name = {a['metadata']['name']: a for a in apps}
    for name in expected:
        app = by_name.get(name, {})
        status = app.get('status', {})
        if status.get('sync', {}).get('status') != 'Synced' or status.get('health', {}).get('status') != 'Healthy':
            failures.append(f'{name}: not Healthy/Synced; inspect Argo conditions and missing images/credentials')
    groups = gh('/orgs/xenomit-do/actions/runner-groups', c)['runner_groups']
    # ARC scale sets do not support custom runner labels; verify their actual group registrations.
    for label in ['xenomit-build', 'xenomit-platform']:
        group = next((g for g in groups if g['name'] == label), None)
        if not group or not group.get('restricted_to_workflows'):
            failures.append(label + ': missing trusted workflow access policy')
            continue
        runners = gh(f'/orgs/xenomit-do/actions/runner-groups/{group["id"]}/runners', c)['runners']
        if not any(r['status'] == 'online' for r in runners):
            failures.append(label + ': no online runner registered')
    host = 'https://atlantis.' + c['domain']
    for path, method, body in [('/', 'GET', None), ('/events', 'POST', b'{}')]:
        try:
            req = urllib.request.Request(host + path, method=method, data=body,
                                         headers={'Content-Type': 'application/json', 'X-GitHub-Event': 'ping'})
            urllib.request.urlopen(req, timeout=20)
            failures.append(path + ': unexpectedly accepted public request')
        except urllib.error.HTTPError as err:
            allowed = {404} if path == '/' else {400, 401, 403}
            if err.code not in allowed:
                failures.append(path + ': endpoint not ready or unexpected rejection')
        except urllib.error.URLError:
            failures.append(path + ': webhook endpoint unreachable')
    if failures:
        raise Failure('\n'.join(failures))
    print('Repository policies, Argo applications, runners, and webhook isolation verified.')


def reconcile(catalog_path, config_path, dry_run=False):
    c = read(config_path)['config']
    catalog = read(catalog_path)
    unknown = [r for r in pages('/orgs/xenomit-do/repos?type=all', c) if r['name'] not in catalog['repositories']]
    if not unknown:
        print('Organization catalog complete.')
        return
    for repo in unknown:
        catalog['repositories'][repo['name']] = {'default_branch': repo['default_branch'], 'workspace': True,
          'ci_profile': 'source', 'required_checks': ['source-check / source-check'], 'atlantis': False, 'archived': repo['archived']}
    if dry_run:
        print('\n'.join(r['name'] for r in unknown))
        return
    repo = '/repos/xenomit-do/xenomit-platform'
    branch = 'automation/catalog-reconcile'
    main = gh(repo + '/git/ref/heads/main', c)['object']['sha']
    ref = gh(repo + '/git/ref/heads/' + branch, c, optional=True)
    if not ref:
        gh(repo + '/git/refs', c, method='POST', data={'ref': 'refs/heads/' + branch, 'sha': main})
    contents = gh(repo + '/contents/repositories.json?ref=' + branch, c)
    gh(repo + '/contents/repositories.json', c, method='PUT', data={
        'message': 'Register repositories discovered in xenomit-do', 'branch': branch,
        'sha': contents['sha'], 'content': base64.b64encode((json.dumps(catalog, indent=2)+'\n').encode()).decode()})
    prs = gh(repo + '/pulls?state=open&head=xenomit-do:' + branch, c)
    if not prs:
        gh(repo + '/pulls', c, method='POST', data={'title': 'Register organization repositories',
          'head': branch, 'base': 'main', 'body': 'Discovered repositories are added to the shared policy catalog. Review visibility, publication audit, CI profile, and required checks before applying.'})



def onboard(catalog_path, config_path, template_path):
    c = read(config_path)['config']
    catalog = read(catalog_path)
    template = Path(template_path).read_bytes()
    for name, definition in catalog['repositories'].items():
        if definition['archived'] or definition['ci_profile'] != 'source':
            continue
        base = f'/repos/{catalog["organization"]}/{name}'
        workflow = '/contents/.github/workflows/source-check.yml'
        existing = gh(base + workflow, c, optional=True)
        if existing and base64.b64decode(existing['content']) == template:
            continue  # Desired CI is already merged; no duplicate PR.
        branch = 'automation/platform-onboarding'
        main = gh(base + '/git/ref/heads/' + definition['default_branch'], c)['object']['sha']
        if not gh(base + '/git/ref/heads/' + branch, c, optional=True):
            gh(base + '/git/refs', c, method='POST', data={'ref': 'refs/heads/'+branch, 'sha': main})
        branch_file = gh(base + workflow + '?ref=' + branch, c, optional=True)
        if not branch_file or base64.b64decode(branch_file['content']) != template:
            change = {'message':'Install managed self-hosted CI gate',
                      'branch':branch, 'content':base64.b64encode(template).decode()}
            if branch_file:
                change['sha'] = branch_file['sha']
            gh(base + workflow, c, method='PUT', data=change)
        prs = gh(base + '/pulls?state=open&head='+catalog['organization']+':'+branch, c)
        if not prs:
            gh(base + '/pulls', c, method='POST', data={'title':'Enable self-hosted CI gate', 'head':branch,
                'base':definition['default_branch'], 'body':'Installs the shared source-check gate on xenomit-build runners. Fork jobs require the fork-ci environment approval. Merge after the check passes.'})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['prepare', 'workspace', 'lease', 'import-identity', 'import-external', 'import-vault', 'inventory', 'verify', 'reconcile', 'onboard'])
    parser.add_argument('arguments', nargs='*')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    functions = {'prepare': prepare, 'workspace': workspace, 'lease': lease,
                 'import-identity': import_identity, 'import-external': import_external, 'import-vault': import_vault,
                 'inventory': inventory, 'verify': verify, 'onboard': onboard}
    try:
        if args.operation == 'reconcile':
            reconcile(*args.arguments, dry_run=args.dry_run)
        else:
            functions[args.operation](*args.arguments)
    except (Failure, KeyError, OSError, ValueError) as error:
        print('platform: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
