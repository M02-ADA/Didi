"""Runs finite native CPU workloads; no app, GPU or 31-case compiler matrix."""
import csv
import json
import os
from pathlib import Path
import subprocess
import sys
import time

binary, output = Path(sys.argv[1]), Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
def run(args, name, timeout=60):
    with (output / f'{name}.stdout').open('w') as stdout, (output / f'{name}.stderr').open('w') as stderr:
        result = subprocess.run([str(binary), *args, '--output', str(output / f'{name}.json')],
                                stdout=stdout, stderr=stderr, timeout=timeout)
    if result.returncode:
        print((output / f'{name}.stderr').read_text(), flush=True)
        if (output / f'{name}.json').exists(): print((output / f'{name}.json').read_text(), flush=True)
        raise SystemExit(f'{name} failed with {result.returncode}; benchmarks not accepted')
    return json.loads((output / f'{name}.json').read_text())

with (output/'backing.stdout').open('w') as out, (output/'backing.stderr').open('w') as err:
    subprocess.run([str(binary.with_name('backing-probe')), str(output/'backing.json')],
                   stdout=out, stderr=err, check=True, timeout=20)
tests = run(['--correctness'], 'correctness', 120)
print(f'Correctness: {sum(x["passed"] for x in tests)}/{len(tests)} passed', flush=True)
all_results = []
for trial in range(1, 3):
    # Counterbalance order. Each process has its own pool/warmup/RSS high-water mark.
    models = ['whole', 'copy'] if trial == 1 else ['copy', 'whole']
    for scenario in ['none', 'moderate', 'slow', 'faults', 'never']:
        for model in models:
            name = f'{trial}-{scenario}-{model}'
            print(f'Benchmark {name}', flush=True)
            item = run(['--model', model, '--scenario', scenario, '--warmup', '12',
                        '--frames', '90', '--hz', '60'], name)
            item['trial'] = trial
            all_results.append(item)
(output / 'benchmarks.json').write_text(json.dumps(all_results, indent=2))

def pct(values, p):
    if not values: return None
    a = sorted(values); rank = (len(a)-1)*p; lo=int(rank); hi=min(lo+1,len(a)-1)
    return a[lo] + (a[hi]-a[lo])*(rank-lo)
rows=[]
for scenario in ['none','moderate','slow','faults','never']:
    for model in ['whole','copy']:
        results=[r for r in all_results if r['model']==model and r['scenario']==scenario]
        ws=[r['window'] for r in results]
        values=lambda key: [v for w in ws for v in w[key]]
        count=sum(w['completed'] for w in ws)
        row={'scenario':scenario,'model':model,'produced':sum(w['produced'] for w in ws),
             'completed_in_window':count, 'cp1_publications':sum(w['cp1Published'] for w in ws),
             'completion_samples':len(values('completionMS')),
             'fps':count/sum(w['observationDurationSeconds'] for w in ws),
             'producer_cpu_p50_ms':pct(values('producerCPU'),.5),'producer_cpu_p95_ms':pct(values('producerCPU'),.95),
             'copy_cpu_p50_ms':pct(values('copyCPU'),.5) if model=='copy' else None,
             'copy_cpu_p95_ms':pct(values('copyCPU'),.95) if model=='copy' else None,
             'handoff_p50_ms':pct(values('handoffMS'),.5),'handoff_p95_ms':pct(values('handoffMS'),.95),
             'return_p50_ms':pct(values('returnMS'),.5) if model=='whole' else None,
             'return_p95_ms':pct(values('returnMS'),.95) if model=='whole' else None,
             'acquire_p50_ms':pct(values('acquireMS'),.5),'acquire_p95_ms':pct(values('acquireMS'),.95),
             'complete_p50_ms':pct(values('completionMS'),.5),'complete_p95_ms':pct(values('completionMS'),.95),
             'cp1_lateness_p95_ms':pct(values('cp1ScheduleLatenessMS'),.95),
             'consumer_wait_p50_ms':pct(values('consumerWaitMS'),.5),'consumer_wait_p95_ms':pct(values('consumerWaitMS'),.95),
             'superseded_capture':sum(w['supersededCaptures'] for w in ws),
             'superseded_data':sum(w['supersededData'] for w in ws),
             'failed':sum(w['failed'] for w in ws),'cancelled':sum(w['cancelled'] for w in ws),
             'peak_rss_mib':max(r['processPeakRSSBytes'] for r in results)/1048576,
             'peak_source_buffers':max(r['finalResources']['peakSourceBuffers'] for r in results),
             'peak_data_pairs':max(r['finalResources']['peakDataPairs'] for r in results),
             'peak_owned_pixel_mib':max(r['finalResources']['peakCombinedBytes'] for r in results)/1048576,
             'peak_copied_mib':max(r['finalResources']['peakDataBytes'] for r in results)/1048576,
             'max_image_mib':max(r['finalResources']['maxImageBytes'] for r in results)/1048576,
             'all_released':all(r['finalResources']['pools']==0 and r['finalResources']['sourceBuffers']==0
                                and r['finalResources']['dataPairs']==0 for r in results),
             'pools_created_max':max(r['finalResources']['poolsCreated'] for r in results)}
        rows.append(row)
(output / 'summary.json').write_text(json.dumps(rows,indent=2))
with (output/'summary.csv').open('w',newline='') as f:
    writer=csv.DictWriter(f,fieldnames=rows[0]);writer.writeheader();writer.writerows(rows)
print('Finished: '+str(output/'summary.json'),flush=True)
