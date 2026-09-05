#!/usr/bin/env python3
"""Validate and mirror approved multi-architecture platform images."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def check_index(raw, expected):
    document = json.loads(raw)
    manifests = document.get("manifests", [])
    actual = {
        f"{item.get('platform', {}).get('os')}/{item.get('platform', {}).get('architecture')}": item.get("digest")
        for item in manifests
    }
    require(document.get("schemaVersion") == 2 and len(manifests) == 2 and actual == expected,
            "INDEX_ARCHITECTURES_MISMATCH")


def mirror_release(release, repository, publisher, run):
    digest = release.get("indexDigest", "")
    version = release.get("version", "")
    reference = release.get("upstreamReference", "")
    architectures = release.get("architectureDigests", {})
    require(re.fullmatch(r"sha256:[a-f0-9]{64}", digest), "INVALID_INDEX_DIGEST")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "INVALID_VERSION")
    require(reference in [f"registry.istio.io/release/proxyv2@{digest}", f"docker.io/istio/proxyv2@{digest}"],
            "UNAPPROVED_SOURCE")
    require(set(architectures) == {"linux/amd64", "linux/arm64"}
            and all(re.fullmatch(r"sha256:[a-f0-9]{64}", item) for item in architectures.values()),
            "INVALID_ARCHITECTURE_LOCK")
    require(re.fullmatch(r"[0-9]{12}\.dkr\.ecr\.(ap-northeast-2|us-east-1)\.amazonaws\.com/[a-z0-9][a-z0-9_./-]*/platform/istio-proxyv2", repository),
            "INVALID_PLATFORM_REPOSITORY")
    require(re.fullmatch(r"[1-9][0-9]*", publisher.get("repositoryId", "")), "INVALID_PUBLISHER_ID")
    require(re.fullmatch(r"https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+/\.github/workflows/publish-platform-images\.yml@refs/heads/main", publisher.get("workflow", "")),
            "INVALID_PUBLISHER_WORKFLOW")
    require(run(["crane", "digest", reference]).strip() == digest, "SOURCE_DIGEST_MISMATCH")
    check_index(run(["crane", "manifest", reference]), architectures)
    target = f"{repository}:{version}"
    run(["crane", "copy", "--no-clobber", reference, target])
    require(run(["crane", "digest", target]).strip() == digest, "TARGET_DIGEST_MISMATCH")
    check_index(run(["crane", "manifest", f"{repository}@{digest}"]), architectures)
    return {
        "schemaVersion": "platform.image-mirror/v1", "upstreamReference": reference,
        "upstreamDigest": digest, "mirroredDigest": digest, "version": version, "publisher": publisher,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", choices=["stable", "candidate"])
    parser.add_argument("--repository", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    workflow = f"https://github.com/{repository}/.github/workflows/publish-platform-images.yml@refs/heads/main"
    require(args.execute and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("GITHUB_REF") == "refs/heads/main"
            and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and os.environ.get("GITHUB_WORKFLOW_REF") == workflow.removeprefix("https://github.com/"),
            "PROTECTED_MAIN_WORKFLOW_REQUIRED")
    publisher = {"repositoryId": os.environ.get("GITHUB_REPOSITORY_ID", ""), "workflow": workflow}
    lock = json.loads((Path(__file__).resolve().parents[2] / "platform-images.lock.json").read_text())
    require(lock.get("schemaVersion") == "platform.image-lock/v1", "INVALID_LOCK_SCHEMA")
    require(not args.output.exists() and not args.output.is_symlink(), "OUTPUT_ALREADY_EXISTS")

    def run(command):
        result = subprocess.run(command, capture_output=True, text=True, timeout=600)
        require(result.returncode == 0, f"REGISTRY_{command[1].upper()}_FAILED")
        return result.stdout

    predicate = mirror_release(lock["releases"][args.release], args.repository, publisher, run)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(predicate, stream, sort_keys=True)
        stream.write("\n")
    print(f"VERIFIED_MIRROR: {args.repository}@{predicate['mirroredDigest']}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        # External stderr and credentials must not enter the attestation job log.
        reason = str(error) if type(error) is ValueError and re.fullmatch(r"[A-Z_]+", str(error)) else "MIRROR_INPUT_OR_EXECUTION_FAILED"
        print(f"FAIL: {reason}", file=sys.stderr)
        sys.exit(1)
