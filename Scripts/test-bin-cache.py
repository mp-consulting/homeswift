#!/usr/bin/env python3
"""Cache only SwiftPM's reported binary directory, never the decision to build.

Unrecognized build flags deliberately bypass the cache. A miss or corrupt file
falls back to SwiftPM; toolchain, package, configuration and environment changes
invalidate the entry. No SwiftPM output-layout assumptions are encoded here.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def location(arguments):
    scratch = None
    index = 0
    while index < len(arguments):
        flag = arguments[index]
        if flag in ("--scratch-path", "--configuration", "-c", "--jobs", "-j"):
            if index + 1 == len(arguments):
                return None
            if flag == "--scratch-path":
                scratch = arguments[index + 1]
            index += 2
        elif any(flag.startswith(name + "=") for name in ("--scratch-path", "--configuration", "--jobs")):
            if flag.startswith("--scratch-path="):
                scratch = flag.split("=", 1)[1]
            index += 1
        else:
            return None
    return Path(scratch).resolve() / ".homeswift-test-bin.json" if scratch else None


def stamp(path):
    path = Path(path).resolve(strict=True)
    info = path.stat()
    return [str(path), info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def signature(arguments):
    swift = subprocess.check_output(["xcrun", "--find", "swift"], text=True).strip()
    developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    inputs = {name: hashlib.sha256(Path(name).read_bytes()).hexdigest()
              for name in ("Package.swift", "Package.resolved") if Path(name).is_file()}
    environment = {key: value for key, value in os.environ.items()
                   if key.startswith(("SWIFT", "SDK", "XCODE", "DYLD"))
                   or key in ("DEVELOPER_DIR", "TOOLCHAINS", "PATH", "CC", "CXX", "HOME")}
    value = [1, str(Path.cwd().resolve()), arguments, inputs, environment,
             stamp(shutil.which("swift")), stamp(swift), stamp(developer),
             stamp(Path(__file__).with_name("build.sh"))]
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def main():
    mode, *arguments = sys.argv[1:]
    if mode == "write":
        binary, *arguments = arguments
    cache = location(arguments)
    if cache is None:
        return 1
    key = signature(arguments)
    if mode == "read":
        entry = json.loads(cache.read_text())
        if entry["key"] != key or not Path(entry["bin"]).is_absolute() or not Path(entry["bin"]).is_dir():
            return 1
        print(entry["bin"])
    elif mode == "write":
        if not Path(binary).is_absolute() or not Path(binary).is_dir():
            return 1
        fd, temporary = tempfile.mkstemp(prefix=cache.name + ".", dir=cache.parent)
        try:
            with os.fdopen(fd, "w") as output:
                json.dump(dict(key=key, bin=binary), output)
            os.replace(temporary, cache)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    else:
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        sys.exit(1)
