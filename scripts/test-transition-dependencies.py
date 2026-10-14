#!/usr/bin/env python3
"""Offline regression tests for independent fixture dependency seeding."""
import importlib.util
import os
import json
import hashlib
import shutil
import subprocess
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("seed", Path(__file__).with_name("seed-transition-dependencies.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SeedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = self.base / "native"
        self.target = self.base / "fixture"
        self.release = self.source / module.TARGET / "release"
        self.release.mkdir(parents=True)

    def put(self, path, content=b"dependency"):
        item = self.source / path
        item.parent.mkdir(parents=True, exist_ok=True)
        item.write_bytes(content)
        return item

    def test_only_dependency_outputs_are_seeded_as_independent_files(self):
        paths = ["release/build/cc-123/out/data", "release/deps/proc_macro.dll", f"{module.TARGET}/release/deps/libserde-abc.rlib", f"{module.TARGET}/release/.fingerprint/serde-abc/lib-serde"]
        excluded = [f"{module.TARGET}/release/xsoc.exe", f"{module.TARGET}/release/deps/xsoc-abc.exe", f"{module.TARGET}/release/deps/xsoc_maintenance-abc.exe", f"{module.TARGET}/release/deps/libxsoc-abc.rlib", "release/build/xsoc-abc/output", f"{module.TARGET}/release/.fingerprint/xsoc-abc/lib-xsoc", f"{module.TARGET}/release/incremental/cache", "debug/deps/not-release"]
        for path in paths + excluded:
            self.put(path)
        result = module.seed(self.source, self.target)
        self.assertEqual(result["files"], len(paths))
        self.assertGreaterEqual(result["seconds"], 0)
        for path in paths:
            self.assertEqual((self.target / path).read_bytes(), b"dependency")
            self.assertFalse(os.path.samefile(self.target / path, self.source / path))
            self.assertEqual((self.target / path).stat().st_nlink, 1)
        for path in excluded:
            self.assertFalse((self.target / path).exists(), path)
        (self.target / paths[0]).write_bytes(b"changed fixture")
        self.assertEqual((self.source / paths[0]).read_bytes(), b"dependency")

    def test_powershell_seed_log_does_not_pollute_returned_msi_path(self):
        caller = (Path(__file__).resolve().parents[1] / "packaging/windows/tests/MsiComponentChecks.ps1").read_text(encoding="utf-8")
        self.assertIn("--source (Join-Path $repositoryRoot 'target') --destination $targetRoot | Out-Host", caller)

    def test_rejects_existing_destination(self):
        self.target.mkdir()
        with self.assertRaisesRegex(ValueError, "fresh"):
            module.seed(self.source, self.target)

    def test_rejects_overlapping_target(self):
        with self.assertRaisesRegex(ValueError, "independent"):
            module.seed(self.source, self.source / "fixture")

    def test_rejects_missing_native_release(self):
        self.release.rmdir()
        with self.assertRaisesRegex(ValueError, "missing"):
            module.seed(self.source, self.target)

    def test_rejects_symlink_dependency(self):
        source = self.put("outside", b"must not follow")
        link = self.source / "release/deps/linked"
        link.parent.mkdir(parents=True)
        try:
            link.symlink_to(source)
        except OSError as error:
            self.skipTest(f"symlink creation unavailable: {error}")
        with self.assertRaisesRegex(ValueError, "links/reparse"):
            module.seed(self.source, self.target)


class CargoSmokeTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("cargo") and shutil.which("rustc"), "Cargo/Rust unavailable")
    def test_real_cargo_reuses_dependency_but_rebuilds_changed_fixture_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dependency = root / "dependency"
            dependency.mkdir()
            (dependency / "Cargo.toml").write_text('[package]\nname="seed-dependency"\nversion="1.0.0"\nedition="2021"\n[lib]\npath="lib.rs"\n')
            (dependency / "lib.rs").write_text('pub fn value() -> u8 { 42 }\n')
            for name, version in (("product", "1.0.0"), ("baseline", "0.255.65535")):
                project = root / name
                project.mkdir()
                (project / "Cargo.toml").write_text(f'[package]\nname="xsoc"\nversion="{version}"\nedition="2021"\n[[bin]]\nname="xsoc"\npath="main.rs"\n[dependencies]\nseed-dependency={{path="../dependency"}}\n')
                (project / "build.rs").write_text('fn main() { println!("cargo:rerun-if-env-changed=XSOC_BUILD_SHA"); println!("cargo:rustc-env=XSOC_BUILD_SHA={}", std::env::var("XSOC_BUILD_SHA").unwrap()); }\n')
                (project / "main.rs").write_text('fn main() { println!("{} {} {}", env!("CARGO_PKG_VERSION"), env!("XSOC_BUILD_SHA"), seed_dependency::value()); }\n')
            host = next(line.removeprefix("host: ") for line in subprocess.check_output(["rustc", "-vV"], text=True).splitlines() if line.startswith("host: "))
            product_target, baseline_target = root / "product-target", root / "baseline-target"
            def build(project, target, revision):
                env = dict(os.environ, XSOC_BUILD_SHA=revision)
                result = subprocess.run(["cargo", "build", "--offline", "--release", "--target", host, "--target-dir", str(target), "--manifest-path", str(root / project / "Cargo.toml"), "--message-format=json"], env=env, check=True, capture_output=True, text=True)
                return [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
            build("product", product_target, "a" * 40)
            def snapshot():
                return {str(path.relative_to(product_target)): hashlib.sha256(path.read_bytes()).hexdigest() for path in product_target.rglob("*") if path.is_file()}
            before = snapshot()
            previous = module.TARGET
            try:
                module.TARGET = host
                metrics = module.seed(product_target, baseline_target)
            finally:
                module.TARGET = previous
            events = build("baseline", baseline_target, "b" * 40)
            artifacts = [event for event in events if event.get("reason") == "compiler-artifact"]
            self.assertTrue(any(event["target"]["name"] == "seed_dependency" and event["fresh"] for event in artifacts))
            self.assertTrue(any(event["target"]["name"] == "xsoc" and not event["fresh"] for event in artifacts))
            suffix = ".exe" if os.name == "nt" else ""
            binary = baseline_target / host / "release" / ("xsoc" + suffix)
            self.assertEqual(subprocess.check_output([str(binary)], text=True).strip(), "0.255.65535 " + "b" * 40 + " 42")
            self.assertEqual(before, snapshot(), "fixture build modified the native target")
            print("Real Cargo fixture copy metrics: " + json.dumps(metrics, sort_keys=True))


if __name__ == "__main__":
    unittest.main()
