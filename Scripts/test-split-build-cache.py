#!/usr/bin/env python3
"""Cache partition integrity, ownership and generation consistency."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('split_cache', Path(__file__).with_name('split-build-cache.py'))
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.build = self.root / 'build'
        self.staging = self.root / 'cache'
        self.build.mkdir()
        self.owner = cache.Ownership({'name': 'homeswift', 'targets': [
            {'name': n} for n in ('HomeswiftPlugin', 'CHAPMath', 'CDNSSD', 'RingTests', 'homeswift-demo')],
            'products': [{'name': 'homeswift'}]})

    def file(self, name, content='object'):
        p = self.build / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        p.chmod(0o750)
        os.utime(p, ns=(1000000000123456789, 1000000000123456789))
        return p

    def snapshot(self):
        return {str(r): (os.readlink(p) if p.is_symlink() else p.read_bytes(),
                        stat.S_IMODE(p.lstat().st_mode), p.lstat().st_mtime_ns)
                for r, p in cache.entries(self.build) if p.is_symlink() or p.is_file()}

    def test_round_trip_both_engines_without_changing_artifacts(self):
        dependency = ['checkouts/nio/source.swift', 'repositories/nio.git/HEAD',
                      'arm64/debug/NIOCore.build/a.o', 'arm64/release/Modules/NIOCore.swiftmodule',
                      'out/Intermediates.noindex/swift-nio.build/Debug/NIOCore-t.build/file.o',
                      'out/Products/Debug/libNIOCore.a', 'out/Products/Debug/NIOCore.swiftmodule/arm64.swiftmodule',
                      'out/ModuleCache.noindex/ABC/Foundation-123.pcm']
        project = ['build.db', 'workspace-state.json', '.built-from',
                   'arm64/debug/NIOCore.build/output-file-map.json',
                   'arm64/debug/NIOCore.build/homeswift.autolink',
                   'out/Intermediates.noindex/swift-nio.build/Debug/NIOCore-t.build/output-file-map.json',
                   'arm64/debug/HomeswiftPlugin.build/a.o', 'arm64/debug/homeswiftPackageTests.build/a.o',
                   'arm64/debug/Modules/RingTests.swiftmodule',
                   'out/Intermediates.noindex/homeswift.build/Debug/CHAPMath.build/a.o',
                   'out/Products/Debug/libHomeswiftPlugin.a', 'out/Products/Debug/homeswift',
                   'out/ModuleCache.noindex/ABC/CHAPMath-123.pcm', 'unknown/new-engine-file']
        for name in dependency + project:
            self.file(name)
        (self.build / 'debug').symlink_to('arm64/debug')
        before = self.snapshot()
        cache.split(self.build, self.staging, self.owner)
        for name in dependency:
            self.assertTrue((self.staging / 'dependencies' / name).exists(), name)
        for name in project:
            self.assertTrue((self.staging / 'project' / name).exists(), name)
        cache.restore(self.build, self.staging)
        self.assertEqual(before, self.snapshot())

    def test_project_changes_keep_dependency_generation_stable(self):
        dep = self.file('arm64/debug/NIOCore.build/a.o')
        project = self.file('arm64/debug/HomeswiftPlugin.build/a.o')
        git_index = self.file('checkouts/nio/.git/index')
        file_map = self.file('arm64/debug/NIOCore.build/output-file-map.json')
        autolink = self.file('arm64/debug/NIOCore.build/homeswift.autolink')
        first = cache.split(self.build, self.staging, self.owner)
        cache.restore(self.build, self.staging)
        project.write_text('new project object')
        git_index.write_text('refreshed Git stat metadata')
        # The hosted runner rewrites these with identical bytes but new dates.
        file_map.touch()
        autolink.touch()
        second = cache.split(self.build, self.staging, self.owner)
        self.assertEqual(first, second)
        cache.restore(self.build, self.staging)
        dep.write_text('new dependency object')
        third = cache.split(self.build, self.staging, self.owner)
        self.assertNotEqual(second, third)

    def test_mismatched_generations_and_overlaps_fail_before_moving(self):
        self.file('arm64/debug/NIOCore.build/a.o')
        self.file('build.db')
        cache.split(self.build, self.staging, self.owner)
        meta = self.staging / 'dependencies' / cache.METADATA
        original = meta.read_text()
        meta.write_text(json.dumps({'version': 1, 'dependency_digest': 'wrong'}))
        with self.assertRaisesRegex(ValueError, 'generations'):
            cache.restore(self.build, self.staging)
        self.assertTrue(cache.empty(self.build))
        meta.write_text(original)
        (self.staging / 'dependencies' / 'build.db').write_text('collision')
        with self.assertRaisesRegex(ValueError, 'overlap'):
            cache.restore(self.build, self.staging)
        self.assertTrue(cache.empty(self.build))

    def test_archive_round_trip_preserves_dependency_generation(self):
        self.file('arm64/debug/NIOCore.build/a.o')
        self.file('build.db')
        first = cache.split(self.build, self.staging, self.owner)
        archive = self.root / 'cache.tar'
        subprocess.run(['tar', '--format=pax', '-cf', str(archive), '-C', str(self.staging), '.'], check=True)
        shutil.rmtree(self.staging)
        self.staging.mkdir()
        subprocess.run(['tar', '-xf', str(archive), '-C', str(self.staging)], check=True)
        cache.restore(self.build, self.staging)
        second = cache.split(self.build, self.staging, self.owner)
        self.assertEqual(first, second)

    def test_partial_cache_and_unsafe_roots(self):
        self.file('checkouts/nio/source.swift')
        cache.split(self.build, self.staging, self.owner)
        # A missing project cache is a valid dependency-only restore.
        (self.staging / 'project' / cache.METADATA).unlink()
        (self.staging / 'project').rmdir()
        cache.restore(self.build, self.staging)
        self.assertTrue((self.build / 'checkouts/nio/source.swift').exists())
        with self.assertRaises(ValueError):
            cache.split(self.build, self.build / 'nested', self.owner)
        with self.assertRaises(ValueError):
            cache.restore(self.build, self.staging)


if __name__ == '__main__':
    unittest.main()
