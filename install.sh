#!/usr/bin/env bash

set -Eeuo pipefail

readonly RELEASE_PUBLIC_KEY="RWSRvQRJKhWlzXJLLMSL9hDjc1WUzo09/7o1BmonsHV0qp0Jb0LZendD"
readonly RELEASE_BASE="https://github.com/Fouchger/homelab/releases/latest/download"

temporary_directory=""
created_container_id=""

cleanup() {
  if [[ -n "$temporary_directory" && -d "$temporary_directory" ]]; then
    rm -rf -- "$temporary_directory"
  fi
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  if [[ -n "$created_container_id" ]]; then
    printf 'Container %s was preserved so the failure can be inspected.\n' \
      "$created_container_id" >&2
  fi
  exit 1
}

trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || fail "run this command in the Proxmox root shell"
[[ "$RELEASE_PUBLIC_KEY" != "__UNRENDERED_RELEASE_KEY__" ]] ||
  fail "the public one-line installer has not been rendered for a release"

for command_name in pveversion pvesh pct pvesm apt-get; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "this does not appear to be a supported Proxmox VE root shell"
done

route_interface="$(
  ip -4 route show default |
    awk '{
      for (field = 1; field <= NF; field++) {
        if ($field == "dev") {
          print $(field + 1)
          exit
        }
      }
    }'
)"
[[ -n "$route_interface" ]] ||
  fail "could not detect the Proxmox management network"

detected_bridge="$route_interface"
detected_vlan=""
if [[ "$route_interface" =~ ^(.+)\.([0-9]+)$ ]]; then
  detected_bridge="${BASH_REMATCH[1]}"
  detected_vlan="${BASH_REMATCH[2]}"
fi
network_bridge="${HOMELAB_BRIDGE:-$detected_bridge}"
network_vlan="${HOMELAB_VLAN:-$detected_vlan}"
[[ "$network_bridge" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail "the detected bridge name is invalid: $network_bridge"
if [[ -n "$network_vlan" ]] &&
  { [[ ! "$network_vlan" =~ ^[0-9]+$ ]] ||
    ((network_vlan < 1 || network_vlan > 4094)); }; then
  fail "the detected VLAN ID is invalid: $network_vlan"
fi
ip link show dev "$network_bridge" >/dev/null 2>&1 ||
  fail "the detected Proxmox bridge does not exist: $network_bridge"
[[ -d "/sys/class/net/${network_bridge}/bridge" ]] ||
  fail "the detected network device is not a Proxmox Linux bridge: $network_bridge"

operating_system="${HOMELAB_OS:-ubuntu}"
case "$operating_system" in
  ubuntu | debian)
    ;;
  *)
    fail "HOMELAB_OS must be ubuntu or debian"
    ;;
esac

select_storage() {
  local content_type="$1"
  local selected
  selected="$(
    pvesm status -content "$content_type" |
      awk 'NR > 1 && $3 == "active" {
        if (!found || $6 > available) {
          name = $1
          available = $6
          found = 1
        }
      }
      END {if (found) print name}'
  )"
  [[ -n "$selected" ]] ||
    fail "no active Proxmox storage supports content type $content_type"
  printf '%s' "$selected"
}

printf 'Preparing the verified Homelab installer...\n'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install --yes --no-install-recommends ca-certificates curl minisign >/dev/null

temporary_directory="$(mktemp -d)"
bootstrap_path="$temporary_directory/create-controlplane-lxc.sh"
installer_path="$temporary_directory/install-controlplane.sh"
container_id_path="$temporary_directory/container-id"

download() {
  local filename="$1"
  curl \
    --fail \
    --location \
    --proto '=https' \
    --show-error \
    --silent \
    --tlsv1.2 \
    --retry 3 \
    --retry-all-errors \
    "$RELEASE_BASE/$filename" \
    --output "$temporary_directory/$filename"
}

for filename in \
  create-controlplane-lxc.sh \
  create-controlplane-lxc.sh.minisig \
  install-controlplane.sh \
  install-controlplane.sh.minisig; do
  download "$filename"
done

minisign -Vm "$bootstrap_path" \
  -x "$bootstrap_path.minisig" \
  -P "$RELEASE_PUBLIC_KEY" >/dev/null ||
  fail "the LXC bootstrap signature is invalid"
minisign -Vm "$installer_path" \
  -x "$installer_path.minisig" \
  -P "$RELEASE_PUBLIC_KEY" >/dev/null ||
  fail "the application installer signature is invalid"

template_storage="$(select_storage vztmpl)"
container_storage="$(select_storage rootdir)"
printf 'Using template storage: %s\n' "$template_storage"
printf 'Using container storage: %s\n' "$container_storage"
printf 'Using network bridge: %s\n' "$network_bridge"
if [[ -n "$network_vlan" ]]; then
  printf 'Using management VLAN: %s\n' "$network_vlan"
else
  printf 'Using the bridge untagged management network.\n'
fi
printf 'Creating the Ubuntu/Debian LXC and installing the application...\n\n'

bootstrap_arguments=(
  --non-interactive
  --os "$operating_system"
  --template-storage "$template_storage"
  --container-storage "$container_storage"
  --bridge "$network_bridge"
  --output-id-file "$container_id_path"
)
if [[ -n "$network_vlan" ]]; then
  bootstrap_arguments+=(--vlan "$network_vlan")
fi
bash "$bootstrap_path" "${bootstrap_arguments[@]}" ||
  fail "LXC creation failed"

[[ -s "$container_id_path" ]] ||
  fail "the LXC bootstrap did not return a container ID"
created_container_id="$(<"$container_id_path")"
[[ "$created_container_id" =~ ^[0-9]+$ ]] ||
  fail "the LXC bootstrap returned an invalid container ID"

printf '\nWaiting for network access inside container %s...\n' \
  "$created_container_id"
network_ready="false"
for _ in {1..60}; do
  if pct exec "$created_container_id" -- \
    getent hosts github.com >/dev/null 2>&1; then
    network_ready="true"
    break
  fi
  sleep 2
done
[[ "$network_ready" == "true" ]] ||
  fail "the new LXC could not resolve github.com"

pct push "$created_container_id" "$installer_path" \
  /root/install-controlplane.sh --perms 0755 >/dev/null ||
  fail "could not copy the application installer into the LXC"
pct exec "$created_container_id" -- \
  bash /root/install-controlplane.sh ||
  fail "application installation failed"
pct exec "$created_container_id" -- \
  rm -f /root/install-controlplane.sh >/dev/null || true

printf '\nAutomated installation completed successfully in container %s.\n' \
  "$created_container_id"
