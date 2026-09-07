#!/usr/bin/env bash
# Tripwires only: public fake injection must stop before any runtime command.
# SDK/HTTP observation fixtures live in dev-evidence-runtime-test.py.
setup_capture_environment() {
  local target=$1
  mkdir -p "$target/bin"
  for tool in aws kubectl gh; do
    cat >"$target/bin/$tool" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected cloud call\n' >"${PLATFORM_CHECK_BIN_DIR%/bin}/cloud-called"
exit 97
EOF
    chmod +x "$target/bin/$tool"
  done
}

run_deployment_fixture() {
  local root=$1 target=$2 image_repository=$3 output=$4
  PLATFORM_CHECK_BIN_DIR="$target/bin" PLATFORM_CHECK_NOW="2026-09-03T10:30:00Z" AWS_PROFILE=mini-commerce \
    bash "$root/scripts/capture-dev-evidence.sh" deployment \
    mini-commerce-dev app-dev mini-commerce-dev play-builder/mini-commerce \
    0123456789abcdef0123456789abcdef01234567 "$image_repository" \
    sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    89abcdef0123456789abcdef0123456789abcdef \
    arn:aws:eks:ap-northeast-2:123456789012:cluster/dev-mini-commerce ap-northeast-2 --output "$output"
}
