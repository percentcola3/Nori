#!/usr/bin/env python3
"""Compare same-host benchmark medians; never silently compare different rigs."""
import argparse
import json
from pathlib import Path


def validate(report):
    if report.get('schemaVersion') != 1 or not report.get('records'):
        raise ValueError('unsupported or empty benchmark report')
    keys = set()
    for row in report['records']:
        key = (row['name'], row['units'], row['unitLabel'])
        if key in keys:
            raise ValueError(f'duplicate workload: {key}')
        keys.add(key)
        if len(row['samples']) < 3 or any(x <= 0 for x in row['samples']):
            raise ValueError(f'invalid samples: {key}')
        if row['medianSeconds'] <= 0 or row['p95Seconds'] < row['medianSeconds']:
            raise ValueError(f'invalid percentiles: {key}')
    return keys


def compare(current, baseline, ratio=1.30, floor=0.1):
    if validate(current) != validate(baseline):
        raise ValueError('workload sets differ; refresh the baseline deliberately')
    for field in ['os', 'architecture', 'cpuModel', 'processors', 'memoryBytes', 'sdk', 'compiler', 'benchmarkSuiteSHA256', 'repetitions', 'fixtureSeed', 'cacheState']:
        if current[field] != baseline[field]:
            raise ValueError(f'incompatible baseline: {field}')
    old = {(r['name'], r['units']): r for r in baseline['records']}
    failures = []
    for row in current['records']:
        ref = old[(row['name'], row['units'])]
        for metric, noise_floor in [('medianSeconds', floor), ('p95Seconds', floor), ('mainActorMaxDelaySeconds', 0.05),
                                    ('medianCPUSeconds', floor), ('processPeakRSSBytes', 32 * 1048576)]:
            limit = max(ref[metric] * ratio, ref[metric] + noise_floor)
            if row[metric] > limit:
                failures.append(f"{row['name']} n={row['units']} {metric}: {row[metric]:.4f} > {limit:.4f}")
    return failures


def self_test():
    import copy
    report = dict(schemaVersion=1, os='test', architecture='test', cpuModel='test', processors=1,
                  memoryBytes=1, sdk='test', compiler='test', benchmarkSuiteSHA256='test', repetitions=5, fixtureSeed=83, cacheState='test',
                  records=[dict(name='scan', units=1000, unitLabel='files', samples=[1, 1, 1], medianSeconds=1,
                                p95Seconds=1, mainActorMaxDelaySeconds=0.01, medianCPUSeconds=0.5, processPeakRSSBytes=1024)])
    assert not compare(report, report)
    slow = copy.deepcopy(report); slow['records'][0]['medianSeconds'] = 2; slow['records'][0]['p95Seconds'] = 2
    assert len(compare(slow, report)) == 2
    jitter = copy.deepcopy(report); jitter['records'][0]['mainActorMaxDelaySeconds'] = 0.2
    assert len(compare(jitter, report)) == 1
    cpu = copy.deepcopy(report); cpu['records'][0]['medianCPUSeconds'] = 2
    assert len(compare(cpu, report)) == 1
    memory = copy.deepcopy(report); memory['records'][0]['processPeakRSSBytes'] = 100 * 1048576
    assert len(compare(memory, report)) == 1
    for mutation in ['hardware', 'missing', 'empty', 'duplicate']:
        invalid = copy.deepcopy(report)
        if mutation == 'hardware': invalid['cpuModel'] = 'other'
        elif mutation == 'missing': invalid['records'][0]['units'] = 10
        elif mutation == 'empty': invalid['records'][0]['samples'] = []
        else: invalid['records'] *= 2
        try: compare(invalid, report)
        except ValueError: pass
        else: raise AssertionError(mutation)
    print('PASS benchmark comparator: equality, timing regression, responsiveness regression, incompatible/missing/invalid baselines')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('current', nargs='?')
    parser.add_argument('--baseline')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test(); return
    if not args.current:
        parser.error('current report required')
    report = json.loads(Path(args.current).read_text())
    validate(report)
    if args.baseline:
        failures = compare(report, json.loads(Path(args.baseline).read_text()))
        for failure in failures: print('REGRESSION ' + failure)
        if failures: raise SystemExit(1)
    print(f"PASS performance report: {len(report['records'])} workloads" + ('; same-host baseline passed' if args.baseline else '; first measured baseline'))


if __name__ == '__main__':
    try: main()
    except (ValueError, KeyError) as error: raise SystemExit(f'FAIL: {error}')
