#!/usr/bin/env bash
set -Eeuo pipefail
chart="${AUTOSCALER_CHART_ARCHIVE:-/tmp/cluster-autoscaler-9.59.0.tgz}"
[[ -f "$chart" ]] || { echo "Supply AUTOSCALER_CHART_ARCHIVE for official 9.59.0 chart" >&2; exit 2; }
[[ "$(shasum -a 256 "$chart" | awk '{print $1}')" == 90276dafe65cf5d4328ef8313baf6cfb9d130683e0c9f3c28a03b4d8a9ed8f6e ]]
helm template fixture "$chart" --set autoDiscovery.clusterName=fixture --set awsRegion=ap-northeast-2 --set-string image.tag=v1.36.0@sha256:dc5d62770338c2902f31b01f95c9fc8c456fd88baa5364ca154d6e47069ec885 |
  yq -e 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image == "registry.k8s.io/autoscaling/cluster-autoscaler:v1.36.0@sha256:dc5d62770338c2902f31b01f95c9fc8c456fd88baa5364ca154d6e47069ec885"'
