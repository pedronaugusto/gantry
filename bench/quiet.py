"""Synthetic scans, every public operation and all graph comparisons, on both revisions."""
import importlib.util
import json
from pathlib import Path
import re
import sys
from quiet_common import Pass

def options(parser):
    parser.add_argument('--comparison-scratch',type=Path)
    parser.add_argument('--skip-setup',action='store_true')

def main():
    p=Pass(__file__,options)
    try:
        source={s:p.snapshot(s) for s in ('before','after')}
        binary={s:p.zig(source[s]) for s in source}
        spec=importlib.util.spec_from_file_location('synthetic',p.here/'run.py')
        synthetic=importlib.util.module_from_spec(spec);spec.loader.exec_module(synthetic)
        corpus=p.build/'corpus';corpus.mkdir(exist_ok=True)
        count=10 if p.smoke else 5000
        if p.preparing:
            total=synthetic.generate(corpus,count)
            (p.build/'corpus-bytes.json').write_text(json.dumps(total))
        else:total=json.loads((p.build/'corpus-bytes.json').read_text())
        p.prepared.require(corpus)
        p.prepared.require(p.build/'corpus-bytes.json')
        def check_scan(out, side=None):
            counts=re.findall(r'edges (\d+), references (\d+), dependencies (\d+), dynamic (\d+)',out)
            if len(counts)!=1:raise ValueError('missing scan counts')
            # Each TypeScript file's import() is an edge of its own where the revision tells it apart.
            dynamic=int(counts[0][3])
            if dynamic not in (0,count) or tuple(map(int,counts[0][:3])) != (15*count+dynamic,7*count,2):raise ValueError('unexpected synthetic graph')
            return {'source_bytes':total,'code_files':6*count,'edges':int(counts[0][0]),'references':int(counts[0][1]),'dependencies':int(counts[0][2])}
        p.interleave('synthetic/list-scan-memory-analysis-aggregate',[(s,[binary[s]/'scan',corpus,'1']) for s in source],check=check_scan)
        sys.path.insert(0,str(p.here/'compare'))
        import run as compare
        from setup import PINS, environment, jdk_home, prepare, prepare_alternatives, verify_alternatives, verify_tools
        import operations
        scratch=(p.args.comparison_scratch or p.here/'build/comparison').resolve()
        # Agreement-only corpora (`"timed": false`) stay out of the timing pass.
        languages=[name for name,pin in PINS['repositories'].items() if pin.get('timed',True)]
        env=prepare(scratch,languages) if p.preparing and not p.args.skip_setup else environment(scratch)
        for asset in ('cargo/bin/cargo-modules','venv/bin/python','npm/node_modules/madge/package.json','npm/node_modules/dependency-cruiser/package.json'):
            p.prepared.require(scratch/asset)
        p.machine['comparison_tools']=verify_tools(scratch,languages,env)
        p.machine['comparison_toolchains']={name:p.run(argv,env=env).strip() for name,argv in {'node':['node','--version'],'go':['go','version'],'rust':['rustc','--version']}.items()}
        if p.preparing and not p.args.skip_setup: prepare_alternatives(scratch,env)
        p.machine['operation_alternatives']=verify_alternatives(scratch,env)
        p.machine['comparison_toolchains']['java']=PINS['jdk']['version']
        operations.run(p,binary,scratch,env,jdk_home(scratch))
        # Comparison tools report boot, import, analysis and output apart on stderr.
        if not p.smoke: env['BENCH_PHASES']='1'
        result={'mode':'smoke' if p.smoke else 'benchmark','pins':PINS,'revisions':p.revisions,'languages':{}}
        for language in languages:
            env['GOWORK']='off'
            folder=p.build/'graphs'/language
            case=folder/'case.json'
            if p.preparing:
                repo,scope,files,commands,go_packages=compare.make_case(language,scratch,folder,env,binary['after']/'compare-scan',p.smoke)
                case.write_text(json.dumps({'repo':str(repo),'scope':scope,'files':sorted(files),
                    'commands':{k:list(map(str,v)) for k,v in commands.items()},'go_packages':go_packages}))
            else:
                saved=json.loads(case.read_text())
                repo,scope,files,commands,go_packages=Path(saved['repo']),saved['scope'],set(saved['files']),saved['commands'],saved['go_packages']
                if repo != scratch/'repos'/language:
                    raise RuntimeError('Comparison scratch differs from preparation; run bench/quiet.sh --smoke')
                pin=PINS['repositories'][language]
                if p.run(['git','-C',repo,'rev-parse','HEAD'],env=env).strip()!=pin['commit'] or p.run(['git','-C',repo,'diff','HEAD','--name-only'],env=env).strip():
                    raise ValueError(f'corpus differs from pinned commit: {repo}')
            if 'pydeps' in commands:
                commands['pydeps']=[scratch/'venv/bin/python',p.here/'compare/quiet-launch.py',*commands['pydeps'][1:]]
            if language=='go':env['GOWORK']=str(repo/'go.work')
            p.prepared.require(case)
            p.prepared.require(folder/'paths.txt')
            if p.plan_only:
                # Prime compiler-backed rivals untimed so the quiet pass performs no compilation.
                for tool,argv in commands.items():
                    if p.args.prepare_only and tool in ('go-list','cargo-modules'):
                        compare.command(argv,repo,env,folder/(tool+'.prepared.raw'))
                continue
            commands={'before':[binary['before']/'compare-scan',repo,folder/'paths.txt'],
                      'after':commands.pop('gantry'),**commands}
            graphs={}
            if not p.smoke:
                for side,argv in commands.items():
                    output=folder/(('gantry' if side=='after' else side)+'.raw')
                    compare.command(argv,repo,env,output)
                    graphs[side]=compare.normalise('gantry' if side in ('before','after') else side,output,repo,files,scope,go_packages)
            for round in range(p.runs):
                for side,argv in commands.items():
                    print(f'  {language}: {side} ({round+1}/{p.runs})',flush=True)
                    output=folder/(('gantry' if side=='after' else side)+'.raw')
                    measured=compare.command(argv,repo,env,output,timed=not p.smoke)
                    graph=compare.normalise('gantry' if side in ('before','after') else side,output,repo,files,scope,go_packages)
                    if side in graphs and graphs[side]!=graph:raise ValueError(f'unstable graph: {language}/{side}')
                    graphs[side]=graph
                    row={'workload':language+'/graph','side':side,'round':round+1,'status':'passed','correctness':{'selected_files':len(files),'edges':len(graph)}}
                    if measured:
                        row['measurements']=measured
                        if found:=operations.phases(output.with_suffix(output.suffix+'.stderr')):row['phases']=found
                    p.rows.append(row);p.save()
            if language=='rust':
                # cargo-modules starts with this workspace discovery; time it alone.
                p.interleave('rust/workspace-discovery',[('cargo-metadata',['cargo','metadata','--format-version','1'])],
                             cwd=repo,env=env,check=operations.cargo_metadata,wall=True)
            (folder/'before.edges.json').write_text(json.dumps(sorted(graphs['before']))+'\n')
            (folder/'after.edges.json').write_text(json.dumps(sorted(graphs['after']))+'\n')
            entry={'scope':scope,'selected_files':len(files),'before_edges':len(graphs['before']),'after_edges':len(graphs['after']),'agreement':{}}
            for tool,graph in graphs.items():
                if tool in ('before','after'):continue
                a=graphs['after'];entry['agreement'][tool]={'agreed':len(a&graph),'after_only':len(a-graph),'comparison_only':len(graph-a)}
                differences=[]
                for direction,edges in [('gantry_only',a-graph),('rival_only',graph-a)]:
                    for edge in sorted(edges):
                        reason,witness=compare.classify(language,direction,edge,repo,folder,{'gantry':a,**graphs},scope)
                        differences.append({'side':'after' if direction=='gantry_only' else tool,'edge':edge,'reason':reason,'witness':witness})
                entry['agreement'][tool]['differences']=differences
            result['languages'][language]=entry
            compare.witnesses.cache_clear()
        if p.plan_only:
            # Compiler-backed rivals must retain their primed outputs and dependency sources.
            p.prepared.require(scratch/'cargo-target')
            p.prepared.require(scratch/'cargo-home')
            p.finish()
            return
        name='smoke-agreement' if p.smoke else 'agreement'
        (p.out/(name+'.json')).write_text(json.dumps(p.clean(result),indent=2)+'\n')
        lines=['# Graph agreement','', 'No timings recorded.' if p.smoke else 'See report.json for interleaved wall/RSS samples.','', '| Language / tool | Agreed | After only | Tool only |','|---|---:|---:|---:|']
        for lang,entry in result['languages'].items():
            for tool,a in entry['agreement'].items():lines.append(f"| {lang} / {tool} | {a['agreed']} | {a['after_only']} | {a['comparison_only']} |")
        (p.out/(name+'.md')).write_text('\n'.join(lines)+'\n')
        p.finish()
    except Exception as error:p.save(str(error));raise

if __name__=='__main__':main()
