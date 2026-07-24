#!/usr/bin/env bash

set -Eeuo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

readonly PRODUCT_NAME="homelab-controlplane"
readonly RELEASE_REPOSITORY="Fouchger/homelab"
readonly RELEASE_PUBLIC_KEY="RWSRvQRJKhWlzXJLLMSL9hDjc1WUzo09/7o1BmonsHV0qp0Jb0LZendD"

temporary_directory=""

cleanup() {
  if [[ -n "$temporary_directory" && -d "$temporary_directory" ]]; then
    rm -rf -- "$temporary_directory"
  fi
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

trap cleanup EXIT

if [[ "${EUID}" -ne 0 ]]; then
  fail "run this installer as root: sudo bash install-controlplane.sh"
fi

if [[ ! "$RELEASE_PUBLIC_KEY" =~ ^R[WT][A-Za-z0-9+/=]+$ ]]; then
  fail "this is an unrendered development installer; use a signed release asset"
fi

if [[ $# -gt 1 ]]; then
  fail "usage: $0 [vMAJOR.MINOR.PATCH]"
fi

requested_tag="${1:-latest}"
if [[ "$requested_tag" != "latest" &&
  ! "$requested_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  fail "invalid release tag: $requested_tag"
fi

[[ -r /etc/os-release ]] || fail "cannot detect the operating system"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID}:${VERSION_ID}" in
  ubuntu:24.04 | debian:13)
    ;;
  *)
    fail "supported systems are Ubuntu 24.04 LTS and Debian 13; detected ${PRETTY_NAME:-unknown}"
    ;;
esac

architecture="$(dpkg --print-architecture 2>/dev/null || true)"
[[ "$architecture" == "amd64" ]] ||
  fail "the current release supports amd64 only; detected ${architecture:-unknown}"

cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '0')"
memory_kib="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
available_kib="$(df -Pk /var | awk 'NR == 2 {print $4}')"
((cpu_count >= 2)) || fail "at least 2 CPU cores are required"
((memory_kib >= 2097152)) || fail "at least 2 GB RAM is required"
((available_kib >= 2097152)) || fail "at least 2 GB free space is required on /var"

export DEBIAN_FRONTEND=noninteractive
printf 'Preparing the supported installation tools...\n'
apt-get update
apt-get install --yes --no-install-recommends ca-certificates curl jq minisign

exec 9>/run/lock/homelab-controlplane-installer.lock
flock -n 9 || fail "another Homelab Control Plane installation is already running"

temporary_directory="$(mktemp -d)"
readonly GitHub_RELEASES="https://github.com/${RELEASE_REPOSITORY}/releases"

download() {
  local url="$1"
  local destination="$2"
  curl \
    --fail \
    --location \
    --proto '=https' \
    --show-error \
    --silent \
    --tlsv1.2 \
    --retry 3 \
    --retry-all-errors \
    "$url" \
    --output "$destination"
}

verify_manifest() {
  local manifest="$1"
  local signature="$2"
  minisign -Vm "$manifest" -x "$signature" -P "$RELEASE_PUBLIC_KEY" >/dev/null
}

fetch_manifest() {
  local base_url="$1"
  local output_prefix="$2"
  download "$base_url/release-manifest.json" "${output_prefix}.json"
  download "$base_url/release-manifest.json.minisig" "${output_prefix}.json.minisig"
  verify_manifest "${output_prefix}.json" "${output_prefix}.json.minisig"
}

if [[ "$requested_tag" == "latest" ]]; then
  printf 'Discovering the latest signed release...\n'
  fetch_manifest \
    "${GitHub_RELEASES}/latest/download" \
    "$temporary_directory/discovery-manifest"
  version="$(jq -er '.version' "$temporary_directory/discovery-manifest.json")" ||
    fail "the signed discovery manifest does not contain a version"
  release_tag="v${version}"
  [[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] ||
    fail "the signed discovery manifest contains an invalid version"
else
  release_tag="$requested_tag"
  version="${release_tag#v}"
fi

version_base="${GitHub_RELEASES}/download/${release_tag}"
printf 'Verifying Homelab Control Plane %s...\n' "$version"
fetch_manifest "$version_base" "$temporary_directory/release-manifest"
manifest="$temporary_directory/release-manifest.json"

jq -e \
  --arg product "$PRODUCT_NAME" \
  --arg version "$version" \
  --arg os_id "$ID" \
  --arg os_version "$VERSION_ID" \
  --arg architecture "$architecture" \
  '.product == $product and
   .version == $version and
   any(.supported_systems[]; .id == $os_id and .version == $os_version) and
   any(.architectures[]; . == $architecture)' \
  "$manifest" >/dev/null ||
  fail "release $release_tag does not support this system"

package_name="$(jq -er \
  '.artifacts[] | select(.type == "debian-package") | .filename' \
  "$manifest")" || fail "the signed manifest does not name a Debian package"
package_sha256="$(jq -er \
  '.artifacts[] | select(.type == "debian-package") | .sha256' \
  "$manifest")" || fail "the signed manifest does not contain the package digest"
package_size="$(jq -er \
  '.artifacts[] | select(.type == "debian-package") | .size' \
  "$manifest")" || fail "the signed manifest does not contain the package size"

[[ "$package_name" == "homelab-controlplane_${version}_amd64.deb" ]] ||
  fail "the signed manifest contains an unexpected package filename"
[[ "$package_sha256" =~ ^[0-9a-f]{64}$ ]] ||
  fail "the signed manifest contains an invalid package digest"
[[ "$package_size" =~ ^[0-9]+$ ]] ||
  fail "the signed manifest contains an invalid package size"

package_path="$temporary_directory/$package_name"
printf 'Downloading the verified package...\n'
download "$version_base/$package_name" "$package_path"
actual_size="$(stat -c '%s' "$package_path")"
actual_sha256="$(sha256sum "$package_path" | awk '{print $1}')"
[[ "$actual_size" == "$package_size" ]] ||
  fail "the downloaded package size does not match the signed manifest"
[[ "$actual_sha256" == "$package_sha256" ]] ||
  fail "the downloaded package digest does not match the signed manifest"

if dpkg-query -W -f='${Status}' "$PRODUCT_NAME" 2>/dev/null |
  grep -Fq 'install ok installed'; then
  backup_directory="/var/backups/homelab-controlplane"
  backup_path="${backup_directory}/preinstall-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  install -d -m 0700 "$backup_directory"
  backup_sources=()
  [[ -d /etc/homelab-controlplane ]] && backup_sources+=(etc/homelab-controlplane)
  [[ -d /var/lib/homelab-controlplane ]] && backup_sources+=(var/lib/homelab-controlplane)
  if ((${#backup_sources[@]})); then
    tar -C / -czf "$backup_path" "${backup_sources[@]}"
    chmod 0600 "$backup_path"
    printf 'Existing configuration backed up to %s\n' "$backup_path"
  fi
fi

printf 'Installing Homelab Control Plane %s...\n' "$version"
if ! apt-get install --yes "$package_path"; then
  printf '\nPackage installation failed. Diagnostics follow:\n' >&2
  dpkg --audit >&2 || true
  dpkg-query -W -f='${Package} ${Status} ${Version}\n' "$PRODUCT_NAME" >&2 || true
  systemctl --no-pager --full status homelab-controlplane.service >&2 || true
  systemctl --no-pager --full status homelab-controlplane-updater.service >&2 || true
  journalctl -u homelab-controlplane.service -u homelab-controlplane-updater.service -n 100 --no-pager >&2 || true
  fail "the Debian package could not be installed; resolve the error above before retrying"
fi
systemctl enable homelab-controlplane.service >/dev/null
systemctl enable homelab-controlplane-updater.service >/dev/null
systemctl restart homelab-controlplane.service
systemctl restart homelab-controlplane-updater.service

ready="false"
for _ in {1..30}; do
  if curl --fail --insecure --silent --show-error \
    https://127.0.0.1:8443/readyz 2>/dev/null |
    jq -e --arg version "$version" \
      '.status == "ok" and .version == $version' >/dev/null; then
    ready="true"
    break
  fi
  sleep 1
done
if [[ "$ready" != "true" ]]; then
  systemctl --no-pager --full status homelab-controlplane.service >&2 || true
  fail "the service did not become ready; inspect: journalctl -u homelab-controlplane"
fi

dashboard_address="$(hostname -I 2>/dev/null | awk '{print $1}')"
dashboard_address="${dashboard_address:-controlplane}"
setup_code="$(journalctl -u homelab-controlplane.service -n 100 -o cat 2>/dev/null |
  sed -n 's/.*first-run setup code: //p' | tail -n 1)"
cat <<EOF

Homelab Control Plane ${version} is installed and healthy.

Open: https://${dashboard_address}:8443/

The preview uses a local self-signed certificate, so your browser will show a
certificate warning. Confirm that you opened the address shown above before
continuing.
EOF
if [[ -n "$setup_code" ]]; then
  printf 'First-run setup code: %s\n' "$setup_code"
else
  printf 'First-run setup code: not available in installer output\n'
fi
printf 'If the service is restarted before setup, retrieve the newest code with:\n'
printf '  journalctl -u homelab-controlplane.service --no-pager | grep "first-run setup code"\n'
