#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
evidence=''
validate_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --evidence) evidence=${2:-}; shift 2 ;;
    --validate-only) validate_only=true; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ -f "$evidence" ]] || fail 'evidence file is required'

jq -e '
  (keys | sort) == (["approval","destinationState","evidenceGrade","expiresAt","observedAt","provider","schemaVersion","sourceState","transition"] | sort) and
  .schemaVersion == "course.oidc-ownership-handoff/v1" and
  .evidenceGrade == "CLOUD_RUNTIME" and
  (.provider | keys | sort) == (["accountId","arn","audiences","issuerUrl"] | sort) and
  (.transition | keys | sort) == (["fromMode","fromOwner","toMode","toOwner"] | sort) and
  (.sourceState | keys | sort) == (["backend","lineage","markerAddress","providerAddress","serial","sha256"] | sort) and
  (.destinationState | keys | sort) == (["backend","imported","lineage","markerAddress","providerAddress","serial"] | sort) and
  (.approval | keys | sort) == (["actor","approvedAt","reason"] | sort) and
  .provider.issuerUrl == "https://token.actions.githubusercontent.com" and
  (.provider.audiences | index("sts.amazonaws.com")) != null and
  (.provider.arn | test("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$")) and
  .provider.accountId == (.provider.arn | split(":")[4]) and
  .transition.fromOwner != .transition.toOwner and
  .transition.fromMode != .transition.toMode and
  .destinationState.imported == true and
  (.sourceState.sha256 | test("^[0-9a-f]{64}$")) and
  (.expiresAt | fromdateiso8601) > (.observedAt | fromdateiso8601)
' "$evidence" >/dev/null || fail 'OIDC_OWNERSHIP_HANDOFF_INVALID'

if [[ "$validate_only" == true ]]; then
  echo 'VALID: course.oidc-ownership-handoff/v1'
  exit 0
fi

fail 'State transfer is intentionally operator-driven: validate evidence, back up state, import destination, verify no-op, then state rm source.'
