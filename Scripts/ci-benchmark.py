#!/usr/bin/env python3
"""Hosted CI measurement; no engine override, product restriction or test filter."""
import json, os, pathlib, platform, subprocess, sys, time
out = pathlib.Path(os.environ['RUNNER_TEMP']) / 'benchmark-results'
out.mkdir(exist_ok=True)
result = out / 'timings.json'
data = json.loads(result.read_text()) if result.exists() else {'platform': platform.platform(), 'policy': os.environ['POLICY'], 'sha': os.environ['GITHUB_SHA'], 'measurements': []}
def run(label, command):
    print(f'::group::{label}', flush=True)
    start = time.monotonic()
    with (out / (label + '.log')).open('w') as log:
        p = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in p.stdout:
            log.write(line)
            print(line, end='', flush=True)
        code = p.wait()
    elapsed = time.monotonic() - start
    data['measurements'].append({'label': label, 'seconds': elapsed, 'exit_code': code, 'command': command})
    result.write_text(json.dumps(data, indent=2) + '\n')
    print(f'::endgroup::\n{label}: {elapsed:.3f}s, exit {code}', flush=True)
    if code: raise SystemExit(code)
if sys.argv[1] == 'shared':
    source = pathlib.Path('Sources/HomeswiftPlugin/PluginHost.swift')
    original = source.read_bytes()
    try:
        for n in range(5):
            source.write_bytes(original + f'\n// CI rebuild measurement {n}\n'.encode())
            run(f'shared-{n+1}', ['Scripts/build.sh', '--all'])
    finally:
        source.write_bytes(original)
    run('restore-shared-source', ['Scripts/build.sh', '--build-tests'])
else:
    run(sys.argv[1], sys.argv[2:])
