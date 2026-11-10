#!/usr/bin/env python3
"""Regression checks for build and test runners; no Swift build required."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class TestRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="homeswift-test-runner-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def script(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o755)

    def test_ci_runner_drains_large_logs_and_preserves_exit_status(self):
        wrapper = self.root / "ci-test.sh"
        shutil.copyfile(SCRIPTS / "ci-test.sh", wrapper)
        self.script(self.root / "test.sh", """python3 - <<'PYTHON'
import os, sys
sys.stdout.write("bundle output\\n" * 200000)
print("FINAL DIAGNOSTIC", file=sys.stderr)
sys.exit(int(os.environ["MOCK_EXIT"]))
PYTHON
""")
        for status in (0, 7):
            result = subprocess.run(
                ["bash", str(wrapper)], capture_output=True, text=True, timeout=30,
                env=dict(os.environ, TMPDIR=str(self.root), MOCK_EXIT=str(status)),
            )
            self.assertEqual(result.returncode, status)
            self.assertEqual(result.stdout.count("bundle output"), 200000)
            self.assertIn("FINAL DIAGNOSTIC", result.stdout)
            self.assertFalse(list(self.root.glob("swift-test-stream.*")))

    def test_build_defaults_preserve_selections_and_explicit_settings(self):
        tools = self.root / "tools"
        self.script(tools / "uname", 'echo "$MOCK_PLATFORM"\n')
        self.script(tools / "swift", 'printf "%s\\n" "$@"\n')
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], MOCK_PLATFORM="Darwin")
        env.pop("HOMESWIFT_BUILD_BATCHES", None)
        batch = ["-Xswiftc", "-driver-batch-count", "-Xswiftc", "2"]
        def call(arguments, **environment):
            return subprocess.run(["bash", str(SCRIPTS / "build.sh"), *arguments], env=dict(env, **environment), capture_output=True, text=True)
        for arguments, expected in [([], ["--product", "homeswift"]), (["--all"], []),
                                    (["--build-tests"], ["--build-tests"]),
                                    (["--target", "HomeswiftTests"], ["--target", "HomeswiftTests"]),
                                    (["--product=homeswift-demo"], ["--product=homeswift-demo"])]:
            result = call(arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["build", *expected, *batch])
        for arguments in [["--all", "-c", "release"], ["--all", "--configuration=release"],
                          ["--all", "--configuration", "release"],
                          ["--all", "-Xswiftc", "-driver-batch-count", "-Xswiftc", "4"],
                          ["--all", "-Xswiftc", "-disable-batch-mode"], ["--help"]]:
            result = call(arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["build", *[x for x in arguments if x != "--all"]])
        for environment in [dict(MOCK_PLATFORM="Linux"), dict(HOMESWIFT_BUILD_BATCHES="0")]:
            self.assertEqual(call(["--all"], **environment).stdout.splitlines(), ["build"])
        self.assertEqual(call(["--all"], HOMESWIFT_BUILD_BATCHES="3").stdout.splitlines(), ["build", *batch[:-1], "3"])
        self.assertNotEqual(call(["--all"], HOMESWIFT_BUILD_BATCHES="bad").returncode, 0)

    def test_dev_all_uses_the_same_build_wrapper(self):
        checkout = self.root / "checkout"
        (checkout / "bin").mkdir(parents=True)
        (checkout / "Scripts").mkdir()
        shutil.copy2(SCRIPTS.parent / "bin/dev", checkout / "bin/dev")
        shutil.copy2(SCRIPTS / "build.sh", checkout / "Scripts/build.sh")
        tools = self.root / "tools"
        self.script(tools / "uname", 'echo "$MOCK_PLATFORM"\n')
        self.script(tools / "swift", 'printf "%s\\n" "$@"\n')
        scratch = str(self.root / "scratch with spaces")
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                   HOMESWIFT_SCRATCH=scratch, HOMESWIFT_BUILD_BATCHES="2")
        for platform, flags in [("Darwin", ["-Xswiftc", "-driver-batch-count", "-Xswiftc", "2"]), ("Linux", [])]:
            result = subprocess.run(["bash", str(checkout / "bin/dev"), "build", "--all"],
                                    env=dict(env, MOCK_PLATFORM=platform), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["build", "--scratch-path", scratch, *flags])

    def test_order_keeps_all_bundles_and_ignores_bad_history(self):
        seed = self.root / "seed"
        history = self.root / "history"
        bundles = self.root / "bundles"
        seed.write_text("12\tCoreTests\n6\tNetworkTests\n1\tFastTests\n")
        history.write_text("2\tCoreTests\n9\tNetworkTests\nNaN\tFastTests\n-3\tCoreTests\n100\tRemovedTests\n")
        paths = [f"/build cache/{name}.xctest" for name in ["NewTests", "CoreTests", "FastTests", "NetworkTests"]]
        bundles.write_text("\n".join(paths) + "\n")
        for timing, expected in [(history, [3, 1, 2, 0]), (Path('/dev/null'), [1, 3, 2, 0])]:
            records = subprocess.check_output(["awk", "-f", str(SCRIPTS / "test-order.awk"), str(seed), str(timing), str(bundles)], text=True)
            ordered = sorted((line.split("\t", 1) for line in records.splitlines()), key=lambda pair: (-float(pair[0]), pair[1]))
            self.assertEqual([path for _, path in ordered], [paths[i] for i in expected])

    def test_binary_location_cache_invalidates_and_falls_back(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ["test-bin-cache.py", "build.sh"]:
            shutil.copy2(SCRIPTS / name, scripts / name)
        tools = self.root / "tools"
        swift = self.root / "compiler"
        swift.write_text("compiler one")
        developer = self.root / "Developer"
        developer.mkdir()
        self.script(tools / "swift", "exit 0\n")
        self.script(tools / "xcrun", 'echo "$MOCK_SWIFT"\n')
        self.script(tools / "xcode-select", 'echo "$MOCK_DEVELOPER"\n')
        scratch = self.root / "cache with spaces"
        scratch.mkdir()
        products = scratch / "actual products"
        products.mkdir()
        manifest = self.root / "Package.swift"
        manifest.write_text("manifest one")
        (self.root / "Package.resolved").write_text("pins one")
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], MOCK_SWIFT=str(swift), MOCK_DEVELOPER=str(developer))
        command = ["python3", str(scripts / "test-bin-cache.py")]
        args = ["--scratch-path", str(scratch)]
        def call(mode, extra=None, environment=None):
            return subprocess.run(command + [mode] + ([str(products)] if mode == "write" else []) + (args if extra is None else extra), cwd=self.root, env=environment or env, capture_output=True, text=True)
        self.assertNotEqual(call("read").returncode, 0)
        self.assertEqual(call("write").returncode, 0)
        self.assertEqual(call("read").stdout.strip(), str(products))
        self.assertNotEqual(call("read", args + ["-c", "release"]).returncode, 0)
        self.assertNotEqual(call("read", args + ["--triple", "different"]).returncode, 0)
        self.assertNotEqual(call("read", environment=dict(env, TOOLCHAINS="another")).returncode, 0)
        for path in [manifest, self.root / "Package.resolved", swift, scripts / "build.sh"]:
            path.write_text(path.read_text() + " changed")
            self.assertNotEqual(call("read").returncode, 0)
            self.assertEqual(call("write").returncode, 0)
        (scratch / ".homeswift-test-bin.json").write_text("broken JSON")
        self.assertNotEqual(call("read").returncode, 0)
        self.assertEqual(call("write").returncode, 0)
        products.rmdir()
        self.assertNotEqual(call("read").returncode, 0)

    def test_only_successful_unfiltered_runs_publish_history(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ["test.sh", "test-order.awk", "test-durations.tsv", "test-bin-cache.py"]:
            shutil.copy2(SCRIPTS / name, scripts / name)
        (scripts / "test-durations.tsv").write_text("20\tSlowTests\n1\tFastTests\n")
        products = self.root / "products"
        for name in ["SlowTests", "FastTests"]:
            binary = products / f"{name}.xctest/Contents/MacOS/{name}"
            binary.parent.mkdir(parents=True)
            binary.touch()
        self.script(scripts / "build.sh", 'printf "%s\\n" "$*" >> "$MOCK_ROOT/build.calls"; for arg in "$@"; do if [ "$arg" = --show-bin-path ]; then echo "$MOCK_PRODUCTS"; fi; done\n')
        tools = self.root / "tools"
        self.script(tools / "uname", "echo Darwin\n")
        self.script(tools / "swift", "exit 0\n")
        self.script(tools / "xcode-select", 'echo "$MOCK_ROOT/Developer"\n')
        self.script(tools / "xcrun", 'echo "$MOCK_ROOT/toolchain/bin/swift"\n')
        (self.root / "toolchain/bin").mkdir(parents=True)
        (self.root / "toolchain/bin/swift").touch()
        (self.root / "Developer").mkdir()
        self.script(self.root / "toolchain/libexec/swift/pm/swiftpm-testing-helper", '''
for arg in "$@"; do if [ "$arg" = --filter ]; then exit 69; fi; done
if [ "${MOCK_FAIL:-0}" = 1 ]; then echo 'intentional failure'; exit 1; fi
echo 'Test run with 1 tests in 1 suites passed after 1.250 seconds.'
''')
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"], MOCK_ROOT=str(self.root), MOCK_PRODUCTS=str(products), HOMESWIFT_TEST_BUNDLES="1", TEST_LOG_DIR=str(self.root / "logs"))
        command = ["bash", str(scripts / "test.sh")]
        history = products / ".homeswift-test-durations.tsv"
        success = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(success.returncode, 0, success.stdout + success.stderr)
        self.assertLess(success.stdout.index("SlowTests"), success.stdout.index("FastTests"))
        saved = history.read_bytes()
        self.assertEqual(set(saved.decode().splitlines()), {"1.250\tSlowTests", "1.250\tFastTests"})
        filtered = subprocess.run(command + ["--", "--filter", "unmatched"], env=env, capture_output=True, text=True)
        self.assertEqual(filtered.returncode, 0, filtered.stdout + filtered.stderr)
        self.assertEqual(history.read_bytes(), saved)
        calls = self.root / "build.calls"
        calls.write_text("")
        focused = subprocess.run(command + ["--target", "SlowTests"], env=env, capture_output=True, text=True)
        self.assertEqual(focused.returncode, 0, focused.stdout + focused.stderr)
        self.assertIn("SlowTests", focused.stdout)
        self.assertNotIn("FastTests", focused.stdout)
        self.assertIn("--target SlowTests", calls.read_text())
        self.assertNotIn("--build-tests", calls.read_text())
        self.assertEqual(history.read_bytes(), saved)
        calls.write_text("")
        skipped = subprocess.run(command + ["--skip-build", "--target=SlowTests"], env=env, capture_output=True, text=True)
        self.assertEqual(skipped.returncode, 0, skipped.stdout + skipped.stderr)
        self.assertEqual(calls.read_text().splitlines(), ["--show-bin-path"])
        self.assertEqual(history.read_bytes(), saved)
        for arguments in [["--target"], ["--target", ""], ["--target="], ["--target", "../../bad"], ["--skip-build", "--target", "MissingTests"]]:
            invalid = subprocess.run(command + arguments, env=env, capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
        failed = subprocess.run(command, env=dict(env, MOCK_FAIL="1"), capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        self.assertEqual(history.read_bytes(), saved)
        # A cache hit avoids only --show-bin-path: the full build still runs.
        scratch = self.root / "build cache"
        scratch.mkdir()
        cached_command = command + ["--scratch-path", str(scratch)]
        warmed = subprocess.run(cached_command, env=env, capture_output=True, text=True)
        self.assertEqual(warmed.returncode, 0, warmed.stdout + warmed.stderr)
        calls.write_text("")
        hit = subprocess.run(cached_command, env=env, capture_output=True, text=True)
        self.assertEqual(hit.returncode, 0, hit.stdout + hit.stderr)
        self.assertIn("--build-tests", calls.read_text())
        self.assertNotIn("--show-bin-path", calls.read_text())
        # Linux keeps SwiftPM's single test executable and receives its arguments unchanged.
        self.script(tools / "uname", "echo Linux\n")
        self.script(tools / "swift", 'printf "%s\\n" "$@" > "$MOCK_ROOT/swift.calls"\n')
        calls.write_text("")
        linux = subprocess.run(command + ["--skip-build", "--scratch-path", "/cache with spaces", "--", "--filter", "SomeSuite"], env=env, capture_output=True, text=True)
        self.assertEqual(linux.returncode, 0, linux.stdout + linux.stderr)
        self.assertEqual(calls.read_text(), "")
        self.assertEqual((self.root / "swift.calls").read_text().splitlines(), ["test", "--skip-build", "--scratch-path", "/cache with spaces", "--filter", "SomeSuite"])
        unsupported = subprocess.run(command + ["--target", "SlowTests"], env=env, capture_output=True, text=True)
        self.assertNotEqual(unsupported.returncode, 0)



if __name__ == "__main__":
    unittest.main()
