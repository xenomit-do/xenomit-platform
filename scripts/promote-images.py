#!/usr/bin/env python3
"""Open a digest-only PR using a token scoped exclusively to deployments."""
import base64,json,os,re,time
from platform import api,Failure
def main():
    token=os.environ['DEPLOYMENTS_TOKEN']
    digests=json.loads(os.environ['IMAGE_DIGESTS'])
    for name in ('orchestrator','web-panel','botd'):
        if not re.fullmatch(r'sha256:[0-9a-f]{64}',digests.get(name,'')):
            raise Failure('Missing or invalid image digest: '+name)
    def gh(path,**kwargs): return api('https://api.github.com','/repos/xenomit-do/xenomit-deployments'+path,token,**kwargs)
    head=gh('/git/ref/heads/main')['object']['sha']
    branch='automation/images-'+os.environ.get('GITHUB_RUN_ID',str(int(time.time())))
    gh('/git/refs',method='POST',data={'ref':'refs/heads/'+branch,'sha':head})
    for name,path in [('orchestrator','apps/control-plane/kustomization.yaml'),('web-panel','apps/panel/kustomization.yaml')]:
        file=gh('/contents/'+path+'?ref=main')
        text=base64.b64decode(file['content']).decode()
        text,count=re.subn(r'digest: sha256:[0-9a-f]{64}','digest: '+digests[name],text)
        if count != 1: raise Failure('Expected one image pin in '+path)
        gh('/contents/'+path,method='PUT',data={'message':'deploy: pin '+name,'branch':branch,'sha':file['sha'],'content':base64.b64encode(text.encode()).decode()})
    # A reference file intentionally does not launch bots; desired fleet remains Git-owned.
    path='fleet/botd-image.json'
    old=gh('/contents/'+path+'?ref=main',optional=True)
    payload={'message':'deploy: record botd digest','branch':branch,'content':base64.b64encode((json.dumps({'image':'ghcr.io/xenomit-do/xenomit-botd@'+digests['botd']},indent=2)+'\n').encode()).decode()}
    if old: payload['sha']=old['sha']
    gh('/contents/'+path,method='PUT',data=payload)
    result=gh('/pulls',method='POST',data={'title':'deploy: promote built image digests','head':branch,'base':'main','body':'Built on the managed runner pool. Review immutable image pins; enable applications only after images are published publicly. The botd reference can be used in reviewed fleet CR changes.'})
    print(result['html_url'])
if __name__ == '__main__': main()
