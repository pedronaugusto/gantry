"""Synthetic scans and all existing graph comparisons, on both revisions."""
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
        total=synthetic.generate(corpus,count)
        def check_scan(out):
            counts=re.findall(r'edges (\d+), references (\d+), dependencies (\d+)',out)
            if len(counts)!=1:raise ValueError('missing scan counts')
            if tuple(map(int,counts[0])) != (15*count,7*count,2):raise ValueError('unexpected synthetic graph')
            return {'source_bytes':total,'code_files':6*count,'edges':int(counts[0][0]),'references':int(counts[0][1]),'dependencies':int(counts[0][2])}
        p.interleave('synthetic/list-scan-memory-analysis-aggregate',[(s,[binary[s]/'scan',corpus,'1']) for s in source],check=check_scan)
        sys.path.insert(0,str(p.here/'compare'))
        import run as compare
        from setup import PINS, environment, prepare, verify_tools
        scratch=(p.args.comparison_scratch or p.here/'build/comparison').resolve()
        languages=list(PINS['repositories'])
        env=environment(scratch) if p.args.skip_setup else prepare(scratch,languages)
        p.machine['comparison_tools']=verify_tools(scratch,languages,env)
        p.machine['comparison_toolchains']={name:p.run(argv,env=env).strip() for name,argv in {'node':['node','--version'],'go':['go','version'],'rust':['rustc','--version']}.items()}
        result={'mode':'smoke' if p.smoke else 'benchmark','pins':PINS,'revisions':p.revisions,'languages':{}}
        for language in languages:
            env['GOWORK']='off'
            folder=p.build/'graphs'/language
            repo,scope,files,commands,go_packages=compare.make_case(language,scratch,folder,env,binary['after']/'compare-scan',p.smoke)
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
                    if measured:row['measurements']=measured
                    p.rows.append(row);p.save()
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
        name='smoke-agreement' if p.smoke else 'agreement'
        (p.out/(name+'.json')).write_text(json.dumps(p.clean(result),indent=2)+'\n')
        lines=['# Graph agreement','', 'No timings recorded.' if p.smoke else 'See report.json for interleaved wall/RSS samples.','', '| Language / tool | Agreed | After only | Tool only |','|---|---:|---:|---:|']
        for lang,entry in result['languages'].items():
            for tool,a in entry['agreement'].items():lines.append(f"| {lang} / {tool} | {a['agreed']} | {a['after_only']} | {a['comparison_only']} |")
        (p.out/(name+'.md')).write_text('\n'.join(lines)+'\n')
        p.finish()
    except Exception as error:p.save(str(error));raise

if __name__=='__main__':main()
