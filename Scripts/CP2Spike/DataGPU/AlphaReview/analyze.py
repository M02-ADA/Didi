#!/usr/bin/env python3
"""Analyze bounded render samples; exclude clipped opaque controls explicitly."""
import json, math, pathlib, sys

def decode(x):
    return x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4

def encode(x):
    return 12.92 * x if x <= 0.0031308 else 1.055 * x ** (1 / 2.4) - 0.055

def analyze(path):
    result = json.loads(pathlib.Path(path).read_text())
    assert result['testsPassed'] == 8 and result['testsFailed'] == 0
    assert result['renderedFrameChecks'] == 64
    assert result['commits'] == result['completions'] == 86
    assert len(result['last16Activations']) == 16
    rows = result['patches']
    metrics = {}
    for mode in sorted(set(p['encoding'] for p in rows)):
        errors = []
        direct = []
        for p in rows:
            if p['encoding'] != mode or p['alpha'] in (0, 1):
                continue
            ref = next(q for q in rows if q['encoding'] == 'straight'
                       and q['nearest'] == p['nearest'] and q['player'] == p['player']
                       and q['background'] == p['background'] and q['sourceColor'] == p['sourceColor']
                       and q['alpha'] == 1)
            for channel, (observed, full) in enumerate(zip(p['observed'], ref['observed'])):
                if not 0.01 < full < 0.99:
                    continue  # Saturated controls cannot identify the unbounded shader output.
                predicted = encode(decode(full) * p['alpha'] + decode(p['background']) * (1 - p['alpha']))
                errors.append(observed - predicted)
                theoretical = encode(decode(p['sourceColor'][channel]) * p['alpha']
                                     + decode(p['background']) * (1 - p['alpha']))
                direct.append(observed - theoretical)
        metrics[mode] = {'unclippedChannelSamples': len(errors),
                         'opaqueCalibratedRMSE': math.sqrt(sum(e*e for e in errors)/len(errors)),
                         'maxAbsError': max(abs(e) for e in errors),
                         'directLinearCompositionRMSE': math.sqrt(sum(e*e for e in direct)/len(direct))}
    # Flat interior samples stay the same with nearest/linear filtering; the broad band is not a filter-only artifact.
    largest_filter_delta = 0
    for p in rows:
        if p['nearest']:
            continue
        other = next(q for q in rows if q['nearest'] and q['encoding'] == p['encoding']
                     and q['player'] == p['player'] and q['background'] == p['background']
                     and q['alpha'] == p['alpha'] and q['sourceColor'] == p['sourceColor'])
        largest_filter_delta = max(largest_filter_delta,
                                  max(abs(a-b) for a,b in zip(p['observed'], other['observed'])))
    assert largest_filter_delta <= 1 / 255 + 1e-9
    if not result['toneMappingEnabled']:
        assert metrics['straight']['maxAbsError'] < 2 / 255
        assert metrics['baselineEncodedPremultiplied']['opaqueCalibratedRMSE'] > 0.05
        assert metrics['linearPremultiplied']['opaqueCalibratedRMSE'] > 0.04
    return {'toneMappingEnabled': result['toneMappingEnabled'], 'metrics': metrics,
            'flatPatchFilterMaxDelta': largest_filter_delta, 'patches': len(rows),
            'renderedFrameChecks': result['renderedFrameChecks'],
            'materialWritesDepthBaseline': result['defaultMaterialWritesDepth'],
            'depthComparisons': result['depthComparisons']}

if __name__ == '__main__':
    summary = {'toneOff': analyze(sys.argv[1]), 'toneOn': analyze(sys.argv[2]),
               'analysisGroupsPassed': 2, 'analysisGroupsFailed': 0,
               'interpretation': 'Straight association fits the unclipped tone-off controls. Tone-on residuals remain; no calibrated production-color acceptance.'}
    pathlib.Path(sys.argv[3]).write_text(json.dumps(summary, indent=2) + '\n')
    print('PASS 2 analysis groups: alpha association and interior filtering controls')
