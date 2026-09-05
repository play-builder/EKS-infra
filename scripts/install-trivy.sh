#!/usr/bin/env bash
set -Eeuo pipefail
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"
: "${TRIVY_VERSION:?TRIVY_VERSION is required}"
: "${TRIVY_ARCHIVE_SHA256:?TRIVY_ARCHIVE_SHA256 is required}"
[[ "$TRIVY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$TRIVY_ARCHIVE_SHA256" =~ ^[a-f0-9]{64}$ ]]
archive=$(mktemp "$RUNNER_TEMP/trivy-archive.XXXXXX")
trap 'rm -f -- "$archive"' EXIT
install_dir="$RUNNER_TEMP/trivy-bin"
curl --fail --silent --show-error --location --retry 3 \
  "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" -o "$archive"
printf '%s  %s\n' "$TRIVY_ARCHIVE_SHA256" "$archive" | shasum -a 256 -c -
mkdir -p "$install_dir"
tar -xzf "$archive" -C "$install_dir" trivy
chmod 755 "$install_dir/trivy"
version=$("$install_dir/trivy" --version)
[[ "$version" == "Version: $TRIVY_VERSION" || "$version" == "Version: $TRIVY_VERSION"$'\n'* ]] || {
  echo 'TRIVY_INSTALLED_VERSION_MISMATCH' >&2; exit 1;
}
printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
printf '%s\n' "$version"
