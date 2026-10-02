#!/usr/bin/env python3
"""Serial feature audit with explicit coverage, per-suite logs, timeout and JSON results."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'script/feature-test-manifest.json'


def load_manifest():
    manifest = json.loads(MANIFEST.read_text())
    accounted = {'test.sh'} | set(manifest['helpers']) | set(manifest['alternateAggregates'])
    for suite in manifest['suites']:
        accounted.add(suite['script']); accounted.update(suite['contains'])
        if not (ROOT / 'script' / suite['script']).is_file():
            raise ValueError(f"missing suite: {suite['script']}")
    discovered = {p.name for p in (ROOT / 'script').glob('test_*.sh')}
    if discovered - accounted:
        raise ValueError(f'uncatalogued test runners: {sorted(discovered - accounted)}')
    for feature in manifest['features']:
        if not feature['suites'] or set(feature['suites']) - accounted:
            raise ValueError(f"invalid feature mapping: {feature['name']}")
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    parser.add_argument('--only', help='comma-separated suite IDs; omitted runs the complete audit')
    parser.add_argument('--list', action='store_true')
    args = parser.parse_args()
    manifest = load_manifest()
    if args.list:
        for feature in manifest['features']: print(feature['name'] + ': ' + ', '.join(feature['suites']))
        return
    if os.environ.get('SM_TEST_SKIP_SWIFT', '0') != '0':
        raise ValueError('complete audit requires Swift tests; unset SM_TEST_SKIP_SWIFT')
    selected = set(args.only.split(',')) if args.only else {s['id'] for s in manifest['suites']}
    unknown = selected - {s['id'] for s in manifest['suites']}
    if unknown: raise ValueError(f'unknown suites: {sorted(unknown)}')
    out = (args.output or ROOT / '.artifacts/all-features' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')).resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    env.setdefault('DEVELOPER_DIR', '/Library/Developer/CommandLineTools')
    # Resolve once before any xcrun-backed compiler invocation; UI fixture
    # subprocesses must share the usable SDK, not discover a newer default.
    # /usr/bin/python3's launcher injects the CLT default SDK alias.
    # Treat that alias as discovery, while honoring an explicit versioned SDK.
    if env.get('SDKROOT') == '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk':
        env.pop('SDKROOT')
    if not env.get('SDKROOT'):
        env['SDKROOT'] = subprocess.check_output(
            ['bash', '-c', 'source "$1"; printf "%s" "$SDKROOT"', 'audit',
             str(ROOT / 'script/test_developer_toolchain.sh')], env=env, text=True).strip()
    report = dict(schemaVersion=1, completeAudit=args.only is None,
                  manifestSHA256=hashlib.sha256(MANIFEST.read_bytes()).hexdigest(),
                  developerDirectory=env['DEVELOPER_DIR'], sdk=env['SDKROOT'],
                  features=manifest['features'], results=[])
    for suite in manifest['suites']:
        if suite['id'] not in selected: continue
        command = ['bash', str(ROOT / 'script' / suite['script'])]
        if suite['id'] == 'performance': command.append(str(out / 'performance.json'))
        log_path = out / (suite['id'] + '.log')
        started = time.monotonic()
        print('RUN ' + suite['id'], flush=True)
        with log_path.open('wb') as log:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            timed_out = False
            try: code = process.wait(timeout=suite['timeoutSeconds'])
            except subprocess.TimeoutExpired:
                timed_out = True; os.killpg(process.pid, signal.SIGTERM)
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: os.killpg(process.pid, signal.SIGKILL); process.wait()
                code = 124
        row = dict(id=suite['id'], exitCode=code, timedOut=timed_out,
                   elapsedSeconds=round(time.monotonic() - started, 3), log=str(log_path))
        report['results'].append(row)
        (out / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
        print(('PASS ' if code == 0 else 'FAIL ') + suite['id'] + f" ({row['elapsedSeconds']}s)", flush=True)
    failures = [r['id'] for r in report['results'] if r['exitCode'] != 0]
    print(f"{len(report['results'])} suites; {len(failures)} failures; report {out / 'results.json'}", flush=True)
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    try: main()
    except ValueError as error: raise SystemExit('FAIL: ' + str(error))
