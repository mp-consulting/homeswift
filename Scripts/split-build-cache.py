#!/usr/bin/env python3
"""Partition SwiftPM cache artifacts without changing compiler inputs or outputs.

Unknown files and the joint build database stay with the project. Restore both
partitions before invoking SwiftPM. Partition keys must include the toolchain,
platform, Package.swift, Package.resolved, and compiler-setting scripts.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess


METADATA = '.homeswift-cache-metadata.json'


class Ownership:
    def __init__(self, package):
        self.package = package['name'].casefold()
        names = {t['name'] for t in package['targets']}
        names.update(p['name'] for p in package.get('products', []))
        names.update(re.sub(r'\W', '_', name) for name in list(names))
        self.names = {name.casefold() for name in names}

    def local(self, name):
        name = name.casefold()
        return name in self.names or name.endswith('tests') or name.startswith(self.package + 'package')

    def owner(self, relative):
        p = relative.parts
        if p[0] in ('checkouts', 'repositories', 'artifacts'):
            return 'dependencies'
        # SwiftPM rewrites these for the current project plan/link, even when
        # it stores them inside an external target's directory. Their dates
        # must travel with the project database, not churn dependency caches.
        if p[-1] == 'output-file-map.json' or relative.suffix == '.autolink':
            return 'project'
        # SwiftBuild groups intermediates by package, including C targets.
        if len(p) >= 3 and p[:2] == ('out', 'Intermediates.noindex') and p[2].endswith('.build'):
            return 'project' if p[2][:-6].casefold() == self.package else 'dependencies'
        # SwiftPM's legacy layout, still the default on some hosted toolchains.
        if len(p) >= 3 and p[1] in ('debug', 'release') and p[2].endswith('.build'):
            return 'project' if self.local(p[2][:-6]) else 'dependencies'
        product = None
        if len(p) >= 4 and p[:2] == ('out', 'Products'):
            product = p[3]
        elif len(p) >= 3 and p[1] in ('debug', 'release'):
            product = p[3] if len(p) >= 4 and p[2] == 'Modules' else p[2]
        if product:
            for suffix in ('.swiftmodule', '.swiftdoc', '.swiftsourceinfo', '.swiftinterface', '.o', '.a'):
                if product.endswith(suffix):
                    name = product[:-len(suffix)]
                    if suffix == '.a' and name.startswith('lib'):
                        name = name[3:]
                    return 'project' if self.local(name) else 'dependencies'
        # SDK/imported modules are stable for this cache's platform/toolchain.
        # Local C modules (e.g. CHAPMath/CDNSSD) must follow project sources.
        module_dirs = {'ModuleCache', 'ModuleCache.noindex', 'SDKExplicitPrecompiledModules',
                       'SwiftExplicitPrecompiledModules', 'ExplicitPrecompiledModules'}
        if module_dirs.intersection(p[:-1]) and relative.suffix in ('.pcm', '.swiftmodule'):
            name = p[-1].split('-')[0].split('.')[0]
            return 'project' if self.local(name) else 'dependencies'
        return None


def entries(root):
    if not root.exists():
        return
    for base, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            p = Path(base) / name
            yield p.relative_to(root), p


def empty(root):
    return not root.exists() or not any(root.iterdir())


def safe_roots(build, cache):
    if build.is_symlink() or cache.is_symlink():
        raise ValueError('Cache roots must not be symlinks')
    a, b = build.resolve(), cache.resolve()
    if a == b or a in b.parents or b in a.parents:
        raise ValueError('Build and staging roots must be separate, non-nested directories')


def attributes(path, metadata):
    os.chmod(path, stat.S_IMODE(metadata.st_mode))
    os.utime(path, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))


def split(build, cache, ownership):
    safe_roots(build, cache)
    if not build.is_dir():
        raise ValueError('Build directory is missing')
    if (build / METADATA).exists():
        raise ValueError('Reserved cache metadata exists in build directory')
    for name in ('dependencies', 'project'):
        if (cache / name).is_symlink() or not empty(cache / name):
            raise ValueError('Staging partition is not empty: ' + name)
        (cache / name).mkdir(parents=True, exist_ok=True)

    def move(source, relative):
        owner = ownership.owner(relative)
        # External target trees also contain project planning/link inputs.
        # Walk them so those files can be separated from compiled objects.
        if (owner == 'dependencies' and source.is_dir() and not source.is_symlink()
                and relative.parts[0] not in ('checkouts', 'repositories', 'artifacts')
                and any(part.endswith('.build') for part in relative.parts)):
            owner = None
        if owner or source.is_symlink() or not source.is_dir():
            destination = cache / (owner or 'project') / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            source.rename(destination)
            return
        metadata = source.stat()
        children = list(source.iterdir())
        if not children:
            destination = cache / 'project' / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            source.rename(destination)
            return
        for child in children:
            move(child, relative / child.name)
        for name in ('dependencies', 'project'):
            destination = cache / name / relative
            if destination.exists():
                attributes(destination, metadata)
        source.rmdir()

    for child in list(build.iterdir()):
        move(child, Path(child.name))
    digest = hashlib.sha256()
    for relative, p in sorted(entries(cache / 'dependencies')):
        # Git refreshes its stat/index metadata after extraction. It is not a
        # compiler input; the compatibility key already pins Package.resolved.
        if relative.parts[0] == 'repositories' or (relative.parts[0] == 'checkouts' and '.git' in relative.parts):
            continue
        if p.is_symlink() or p.is_file():
            st = p.lstat()
            digest.update(json.dumps([str(relative), st.st_mode, st.st_mtime_ns, st.st_size]).encode())
            if p.is_symlink():
                digest.update(os.readlink(p).encode())
            else:
                with p.open('rb') as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(chunk)
    metadata = {'version': 1, 'dependency_digest': digest.hexdigest()}
    for name in ('dependencies', 'project'):
        (cache / name / METADATA).write_text(json.dumps(metadata) + '\n')
    return metadata


def restore(build, cache):
    safe_roots(build, cache)
    if not empty(build):
        raise ValueError('Restore requires an empty build directory')
    partitions = [cache / name for name in ('dependencies', 'project')]
    metadata = [json.loads((p / METADATA).read_text()) for p in partitions if (p / METADATA).exists()]
    if metadata and (any(m.get('version') != 1 for m in metadata) or any(m != metadata[0] for m in metadata)):
        raise ValueError('Dependency and project cache generations do not match')
    seen = {}
    for root in partitions:
        if root.is_symlink():
            raise ValueError('A partition root must not be a symlink')
        for relative, p in entries(root):
            if str(relative) == METADATA:
                continue
            directory = p.is_dir() and not p.is_symlink()
            if relative in seen and not (seen[relative] and directory):
                raise ValueError('Partitions overlap: ' + str(relative))
            seen[relative] = directory
    build.mkdir(parents=True, exist_ok=True)

    def merge(source, destination):
        if not destination.exists() and not destination.is_symlink():
            source.rename(destination)
        else:
            metadata = source.stat()
            for child in list(source.iterdir()):
                merge(child, destination / child.name)
            attributes(destination, metadata)
            source.rmdir()

    for root in partitions:
        if root.exists():
            for child in list(root.iterdir()):
                if child.name == METADATA:
                    child.unlink()
                else:
                    merge(child, build / child.name)
            root.rmdir()


def inventory(build, ownership):
    result = {name: {'files': 0, 'bytes': 0} for name in ('dependencies', 'project')}
    for relative, p in entries(build):
        if p.is_symlink() or p.is_file():
            owner = ownership.owner(relative) or 'project'
            result[owner]['files'] += 1
            result[owner]['bytes'] += p.lstat().st_size
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['split', 'restore', 'inventory'])
    parser.add_argument('--build-dir', type=Path, default=Path('.build'))
    parser.add_argument('--cache-dir', type=Path, default=Path('.ci-build-cache'))
    parser.add_argument('--package-json', type=Path, help='swift package dump-package output (optional)')
    args = parser.parse_args()
    if args.operation == 'restore':
        restore(args.build_dir, args.cache_dir)
        return
    package = json.loads(args.package_json.read_text() if args.package_json else
                         subprocess.check_output(['swift', 'package', 'dump-package'], text=True))
    ownership = Ownership(package)
    report = inventory(args.build_dir, ownership)
    if args.operation == 'split':
        report.update(split(args.build_dir, args.cache_dir, ownership))
    print(json.dumps(report, sort_keys=True))


if __name__ == '__main__':
    main()
