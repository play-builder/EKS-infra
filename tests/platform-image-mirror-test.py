import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mirror", ROOT / "scripts/lib/platform-image-mirror.py")
MIRROR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MIRROR)
DIGEST = "sha256:" + "a" * 64
AMD = "sha256:" + "b" * 64
ARM = "sha256:" + "c" * 64
REPOSITORY = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/team/platform/istio-proxyv2"
RELEASE = {
    "version": "1.30.4", "upstreamReference": "registry.istio.io/release/proxyv2@" + DIGEST,
    "indexDigest": DIGEST, "architectureDigests": {"linux/amd64": AMD, "linux/arm64": ARM},
}
PUBLISHER = {
    "repositoryId": "405337777",
    "workflow": "https://github.com/play-builder/EKS-infra/.github/workflows/publish-platform-images.yml@refs/heads/main",
}
INDEX = {"schemaVersion": 2, "mediaType": "application/vnd.docker.distribution.manifest.list.v2+json", "manifests": [
    {"digest": AMD, "platform": {"os": "linux", "architecture": "amd64"}},
    {"digest": ARM, "platform": {"os": "linux", "architecture": "arm64"}},
]}


class Registry:
    def __init__(self, source_digest=DIGEST, target_digest=DIGEST, source_index=None, target_index=None):
        self.source_digest = source_digest
        self.target_digest = target_digest
        self.source_index = INDEX if source_index is None else source_index
        self.target_index = INDEX if target_index is None else target_index
        self.calls = []

    def run(self, args):
        self.calls.append(args)
        source = args[-1].startswith("registry.istio.io/")
        if args[:2] == ["crane", "digest"]:
            return self.source_digest if source else self.target_digest
        if args[:2] == ["crane", "manifest"]:
            return json.dumps(self.source_index if source else self.target_index)
        if args[:2] == ["crane", "copy"]:
            return ""
        raise AssertionError(f"unexpected external command: {args}")


class PlatformMirrorTest(unittest.TestCase):
    def test_cli_refuses_unprotected_local_execution_without_creating_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "predicate.json"
            environment = {k: v for k, v in os.environ.items() if not k.startswith("GITHUB_")}
            result = subprocess.run([sys.executable, str(ROOT / "scripts/lib/platform-image-mirror.py"),
                                     "stable", "--repository", REPOSITORY, "--output", str(target), "--execute"],
                                    capture_output=True, text=True, env=environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("PROTECTED_MAIN_WORKFLOW_REQUIRED", result.stderr)
            self.assertFalse(target.exists())

    def test_mirror_attests_only_checked_source_and_unchanged_multiarch_target(self):
        registry = Registry()
        result = MIRROR.mirror_release(RELEASE, REPOSITORY, PUBLISHER, registry.run)
        self.assertEqual(result, {
            "schemaVersion": "platform.image-mirror/v1", "upstreamReference": RELEASE["upstreamReference"],
            "upstreamDigest": DIGEST, "mirroredDigest": DIGEST, "version": "1.30.4", "publisher": PUBLISHER,
        })
        self.assertEqual(registry.calls, [
            ["crane", "digest", RELEASE["upstreamReference"]],
            ["crane", "manifest", RELEASE["upstreamReference"]],
            ["crane", "copy", "--no-clobber", RELEASE["upstreamReference"], REPOSITORY + ":1.30.4"],
            ["crane", "digest", REPOSITORY + ":1.30.4"],
            ["crane", "manifest", REPOSITORY + "@" + DIGEST],
        ])

    def test_source_digest_mismatch_never_copies(self):
        registry = Registry(source_digest="sha256:" + "d" * 64)
        with self.assertRaisesRegex(ValueError, "SOURCE_DIGEST_MISMATCH"):
            MIRROR.mirror_release(RELEASE, REPOSITORY, PUBLISHER, registry.run)
        self.assertFalse(any(c[1] == "copy" for c in registry.calls))

    def test_target_digest_change_cannot_produce_attestable_predicate(self):
        with self.assertRaisesRegex(ValueError, "TARGET_DIGEST_MISMATCH"):
            MIRROR.mirror_release(RELEASE, REPOSITORY, PUBLISHER, Registry(target_digest="sha256:" + "d" * 64).run)

    def test_each_architecture_must_match_before_and_after_copy(self):
        for position in ["source_index", "target_index"]:
            for mutation in ["missing", "changed", "duplicate"]:
                with self.subTest(position=position, mutation=mutation):
                    index = copy.deepcopy(INDEX)
                    if mutation == "missing":
                        index["manifests"].pop()
                    elif mutation == "changed":
                        index["manifests"][0]["digest"] = "sha256:" + "d" * 64
                    else:
                        index["manifests"].append(copy.deepcopy(index["manifests"][0]))
                    registry = Registry(**{position: index})
                    with self.assertRaisesRegex(ValueError, "INDEX_ARCHITECTURES_MISMATCH"):
                        MIRROR.mirror_release(RELEASE, REPOSITORY, PUBLISHER, registry.run)
                    if position == "source_index":
                        self.assertFalse(any(c[1] == "copy" for c in registry.calls))

    def test_unapproved_registry_destination_or_publisher_rejected_before_network(self):
        cases = [
            (RELEASE, "docker.io/company/istio", PUBLISHER),
            ({**RELEASE, "upstreamReference": "evil.example/istio@" + DIGEST}, REPOSITORY, PUBLISHER),
            ({**RELEASE, "upstreamReference": "registry.istio.io/release/proxyv2:latest"}, REPOSITORY, PUBLISHER),
            (RELEASE, REPOSITORY, {**PUBLISHER, "repositoryId": ""}),
            (RELEASE, REPOSITORY, {**PUBLISHER, "workflow": PUBLISHER["workflow"].replace("refs/heads/main", "refs/heads/dev")}),
        ]
        for release, repository, publisher in cases:
            with self.subTest(repository=repository, publisher=publisher):
                registry = Registry()
                with self.assertRaises(ValueError):
                    MIRROR.mirror_release(release, repository, publisher, registry.run)
                self.assertEqual(registry.calls, [])


if __name__ == "__main__":
    unittest.main()
