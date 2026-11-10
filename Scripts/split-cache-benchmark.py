#!/usr/bin/env python3
import json, os, pathlib, platform, shutil, subprocess, sys, time
root = pathlib.Path(os.environ['RUNNER_TEMP']) / 'split-results'
out = root / os.environ.get('POLICY', 'seed')
out.mkdir(parents=True, exist_ok=True)
result = out / 'timings.json'
data = json.loads(result.read_text()) if result.exists() else {'platform': platform.platform(), 'cpus': os.cpu_count(), 'swift': subprocess.check_output(['swift', '--version'], text=True).strip(), 'policy': os.environ.get('POLICY', 'seed'), 'sha': os.environ['GITHUB_SHA'], 'measurements': []}
def run(label, command):
    print(f'::group::{label}', flush=True)
    start = time.monotonic()
    with (out / (label + '.log')).open('w') as log:
        p = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for line in p.stdout:
            log.write(line); print(line, end='', flush=True)
        code = p.wait()
    seconds = time.monotonic() - start
    data['measurements'].append({'label': label, 'seconds': seconds, 'exit_code': code, 'command': command})
    result.write_text(json.dumps(data, indent=2) + '\n')
    print(f'::endgroup::\n{label}: {seconds:.3f}s, exit {code}', flush=True)
    if code: raise SystemExit(code)
if sys.argv[1] == 'shared':
    source = pathlib.Path('Sources/HomeswiftPlugin/PluginHost.swift'); original = source.read_bytes()
    try:
        for n in range(5):
            source.write_bytes(original + f'\n// Split-cache shared-runtime measurement {n}\n'.encode())
            run(f'shared-{n+1}', ['Scripts/build.sh', '--all'])
    finally: source.write_bytes(original)
    run('restore-shared-source', ['Scripts/build.sh', '--build-tests'])
elif sys.argv[1] == 'clear':
    p = pathlib.Path('.build')
    assert not p.is_symlink()
    if p.exists(): shutil.rmtree(p)
else: run(sys.argv[1], sys.argv[2:])
