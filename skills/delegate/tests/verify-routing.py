from pathlib import Path
import os, subprocess, tempfile, json
scripts=Path(__file__).resolve().parent.parent/'scripts'
with tempfile.TemporaryDirectory(prefix='delegate-check-') as tmp:
    root=Path(tmp); binary=root/'bin'; binary.mkdir(); home=root/'codex-home'; home.mkdir()
    cache=root/'cache'; cache.mkdir(); logs=root/'logs'; logs.mkdir(); inputs=root/'inputs'; inputs.mkdir()
    work=root/'work'; work.mkdir(); (inputs/'task.md').write_text('Read only for sub/review. Implementation fixture.\n')
    for role in ['impl','sub','review']: (home/f'{role}.config.toml').write_text('')
    (cache/'codex-models.json').write_text(json.dumps({'models':[{'slug':'gpt-5.6-sol'}]}))
    (cache/'claude-models.json').write_text('claude-impl-test\nclaude-other-test\nclaude-review-test\n')
    routing=root/'routing.tsv'; tiers=root/'tiers.tsv'; tiers.write_text('codex\tgpt-5.6-sol\t1\nclaude\tclaude-impl-test\t3\nclaude\tclaude-other-test\t2\nclaude\tclaude-review-test\t1\n')
    shim='''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
with open(os.environ['TEST_LOG'],'a') as f: f.write(json.dumps({'cli':Path(sys.argv[0]).name,'args':sys.argv[1:]})+'\\n')
print('DELEGATE_CHANGED_FILE\\t'+os.environ['TEST_WORK']+'/result.txt')
sys.exit(int(os.environ.get('TEST_RC','0')))
'''
    for cli in ['codex','claude']:
        p=binary/cli; p.write_text(shim); p.chmod(0o755)
    env=dict(os.environ,PATH=str(binary)+':'+os.environ['PATH'], CODEX_HOME=str(home), DELEGATE_ROUTING_FILE=str(routing),DELEGATE_MODEL_CACHE_DIR=str(cache),DELEGATE_MODEL_TIERS_FILE=str(tiers),TEST_LOG=str(logs/'calls'),TEST_WORK=str(work),TMPDIR=str(root))
    entrypoints=[('codex-exec.sh','impl','implementation'),('claude-impl-exec.sh','impl','implementation'),('claude-sub-exec.sh','sub','other'),('claude-review-agent-exec.sh','review','review')]
    claude_agents={'implementation':'impl','other':'impl','review':'review'}
    claude_models={'implementation':'claude-impl-test','other':'claude-other-test','review':'claude-review-test'}
    count=0
    for backend in ['codex','claude']:
        routing.write_text(''.join(f'{task}\t{backend}\t{role if backend=="claude" else ""}\t{"gpt-5.6-sol" if backend=="codex" else claude_models[task]}\n' for task,role in [('implementation','impl'),('other','impl'),('review','review')]))
        for entry,role,task_type in entrypoints:
            for rc in [0,7]:
                result=subprocess.run(['bash',str(scripts/entry),str(work),'task.md',str(inputs)],env=dict(env,TEST_RC=str(rc)),capture_output=True,text=True)
                assert result.returncode==rc,(entry,backend,rc,result)
                assert 'unbound variable' not in result.stderr,result.stderr
                call=json.loads((logs/'calls').read_text().splitlines()[-1]); assert call['cli']==backend,call
                args=call['args']
                if backend=='codex':
                    assert args[args.index('--profile')+1]==role,call
                    assert args[args.index('--model')+1]=='gpt-5.6-sol',call
                    assert args[args.index('--sandbox')+1]==('read-only' if role in ['sub','review'] else 'workspace-write'),call
                    assert '--dangerously-bypass-approvals-and-sandbox' not in args,call
                else:
                    assert args[args.index('--agent')+1]==claude_agents[task_type],call
                    assert args[args.index('--model')+1]==claude_models[task_type],call
                if role=='impl': assert f'DELEGATE_REVIEW_FILE\t{work}/result.txt' in result.stdout,result.stdout
                assert ('DELEGATE_FALLBACK_SUGGEST' in result.stderr)==(rc!=0),result.stderr
                assert not list(root.glob('tmp.*')),list(root.glob('tmp.*'))
                count+=1
    routing.write_text('implementation\tcodex\t\tgpt-5.6-sol\n')
    (home/'impl.config.toml').unlink()
    before=(logs/'calls').read_text()
    result=subprocess.run(['bash',str(scripts/'codex-exec.sh'),str(work),'task.md',str(inputs)],env=env,capture_output=True,text=True)
    assert result.returncode==1 and 'Codex profile not found' in result.stderr,result
    assert (logs/'calls').read_text()==before
    count+=1
    print(f'PASS: {count} cases (both backends, 4 entrypoints, exit 0/7, profile/sandbox/model, cleanup, missing profile fail-closed)')
