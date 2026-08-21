#!/usr/bin/env bash
# ==============================================================================
# Controlplane Proxmox Release Bootstrap
# Downloads, verifies and runs one exact public runtime release.
# ==============================================================================

set -Eeuo pipefail

readonly GITHUB_REPOSITORY="Fouchger/Homelab"
readonly RELEASE_CHANNEL="stable"
RELEASE_TAG=""

colour_cyan='\033[1;36m'
colour_green='\033[1;32m'
colour_red='\033[1;31m'
colour_reset='\033[0m'

log() {
  printf '%b🚀 %s%b\n' "$colour_cyan" "$*" "$colour_reset"
}

fail() {
  printf '%b✖ %s%b\n' "$colour_red" "$*" "$colour_reset" >&2
  exit 1
}

usage() {
  printf '%s\n' 'Usage: install-proxmox.sh --release vMAJOR.MINOR.PATCH[-test.NUMBER]'
}

while (($# > 0)); do
  case "$1" in
    --release) RELEASE_TAG="${2:-}"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$RELEASE_TAG" ]] || {
  usage
  fail 'A specific release is required.'
}

if [[ "$RELEASE_CHANNEL" == "test" ]]; then
  [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-test\.[0-9]+$ ]] || \
    fail "The test branch accepts test releases only: vMAJOR.MINOR.PATCH-test.NUMBER"
else
  [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    fail "The main branch accepts stable releases only: vMAJOR.MINOR.PATCH"
fi

for command_name in curl sha256sum tar; do
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command is missing: $command_name"
done

readonly ASSET_NAME="controlplane-proxmox-${RELEASE_TAG}.tar.gz"
readonly DOWNLOAD_ROOT="https://github.com/${GITHUB_REPOSITORY}/releases/download/${RELEASE_TAG}"
readonly TEMPORARY_DIRECTORY="$(mktemp -d)"

cleanup() {
  rm -rf -- "$TEMPORARY_DIRECTORY"
}
trap cleanup EXIT

log "Downloading Controlplane ${RELEASE_TAG} from the ${RELEASE_CHANNEL} channel"
curl -fsSL --retry 3 --retry-delay 2 \
  "${DOWNLOAD_ROOT}/${ASSET_NAME}" \
  -o "${TEMPORARY_DIRECTORY}/${ASSET_NAME}"
curl -fsSL --retry 3 --retry-delay 2 \
  "${DOWNLOAD_ROOT}/${ASSET_NAME}.sha256" \
  -o "${TEMPORARY_DIRECTORY}/${ASSET_NAME}.sha256"

log 'Verifying the SHA-256 checksum'
(
  cd "$TEMPORARY_DIRECTORY"
  sha256sum -c "${ASSET_NAME}.sha256"
)

tar -xzf "${TEMPORARY_DIRECTORY}/${ASSET_NAME}" -C "$TEMPORARY_DIRECTORY"
log 'Starting the interactive Proxmox LXC installer'
bash "${TEMPORARY_DIRECTORY}/controlplane-platform/bin/controlplane-lxc"
printf '%b✔ Controlplane Proxmox installation completed.%b\n' "$colour_green" "$colour_reset"
