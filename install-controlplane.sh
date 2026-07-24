#!/usr/bin/env bash
set -euo pipefail

release_tag="${1:-}"
if [[ -z "$release_tag" ]]; then
  echo "usage: $0 <release-tag>" >&2
  exit 2
fi
if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "invalid release tag: $release_tag" >&2
  exit 1
fi

version="${release_tag#v}"
asset="homelab-controlplane_${version}_amd64.deb"
base="https://github.com/Fouchger/homelab/releases/download/${release_tag}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
  "$base/$asset" --output "$tmp_dir/$asset"
apt-get install --yes "$tmp_dir/$asset"
systemctl enable --now homelab-controlplane.service
curl --fail --silent --show-error http://127.0.0.1:8080/healthz
