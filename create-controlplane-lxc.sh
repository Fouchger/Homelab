#!/usr/bin/env bash

set -Eeuo pipefail

readonly COMMUNITY_SCRIPTS_REPOSITORY="community-scripts/ProxmoxVE"
readonly COMMUNITY_SCRIPTS_BASE_URL="https://raw.githubusercontent.com/${COMMUNITY_SCRIPTS_REPOSITORY}/main/ct"
readonly PUBLIC_INSTALL_GUIDE="https://github.com/Fouchger/homelab/blob/main/docs/installation.md"

cleanup_directory=""

cleanup() {
  if [[ -n "$cleanup_directory" && -d "$cleanup_directory" ]]; then
    rm -rf -- "$cleanup_directory"
  fi
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

trap cleanup EXIT

if [[ "${EUID}" -ne 0 ]]; then
  fail "run this bootstrap as root in the Proxmox VE shell"
fi

for command_name in pveversion pvesh pct curl sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "required Proxmox command is missing: $command_name"
done

architecture="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$architecture" in
  amd64 | x86_64)
    ;;
  *)
    fail "the first Homelab Control Plane package supports amd64 only; detected $architecture"
    ;;
esac

cat <<'EOF'
Homelab Control Plane LXC bootstrap

This bootstrap runs on the Proxmox host as root. It downloads and runs the
selected third-party Community Scripts LXC creator.

The Community Scripts code creates and configures the LXC and may retain its
own defaults or logs on the Proxmox host. Homelab Control Plane itself is not
installed on the host.

Choose the operating system:
  1) Ubuntu 24.04 LTS (recommended)
  2) Debian 13
  q) Cancel
EOF

while true; do
  read -r -p "Selection [1]: " operating_system_choice
  operating_system_choice="${operating_system_choice:-1}"

  case "$operating_system_choice" in
    1)
      operating_system_name="Ubuntu 24.04 LTS"
      operating_system_id="ubuntu"
      operating_system_version="24.04"
      helper_url="${COMMUNITY_SCRIPTS_BASE_URL}/ubuntu.sh"
      break
      ;;
    2)
      operating_system_name="Debian 13"
      operating_system_id="debian"
      operating_system_version="13"
      helper_url="${COMMUNITY_SCRIPTS_BASE_URL}/debian.sh"
      break
      ;;
    q | Q)
      printf 'Cancelled. No container was created.\n'
      exit 0
      ;;
    *)
      printf 'Enter 1, 2, or q.\n' >&2
      ;;
  esac
done

container_id="$(pvesh get /cluster/nextid 2>/dev/null)" ||
  fail "could not obtain the next available Proxmox container ID"

if [[ ! "$container_id" =~ ^[0-9]+$ ]]; then
  fail "Proxmox returned an invalid container ID: $container_id"
fi

cleanup_directory="$(mktemp -d)"
helper_path="${cleanup_directory}/${operating_system_id}.sh"

printf '\nDownloading the official Community Scripts %s helper...\n' \
  "$operating_system_name"
curl \
  --fail \
  --location \
  --proto '=https' \
  --show-error \
  --silent \
  --tlsv1.2 \
  "$helper_url" \
  --output "$helper_path"

if [[ ! -s "$helper_path" ]]; then
  fail "the downloaded Community Scripts helper is empty"
fi

helper_digest="$(sha256sum "$helper_path" | awk '{print $1}')"

cat <<EOF

Third-party source:
  ${helper_url}

Downloaded SHA-256:
  ${helper_digest}

Selected container:
  ID:       ${container_id}
  Hostname: controlplane
  OS:       ${operating_system_name}
  CPU:      4 cores
  RAM:      4096 MB
  Disk:     32 GB
  Network:  DHCP on vmbr0
  Type:     Unprivileged
  Nesting:  Disabled

The wrapper forces the upstream helper's Default mode. If the Proxmox node has
multiple eligible storage locations, the upstream helper may still ask you to
choose template and container storage. No other var_* values from your shell
are passed into the helper.

Type RUN to execute this third-party script as root on Proxmox.
EOF

read -r -p "Confirmation: " confirmation
if [[ "$confirmation" != "RUN" ]]; then
  printf 'Cancelled. No container was created.\n'
  exit 0
fi

env -i \
  HOME="/root" \
  LANG="C.UTF-8" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  SHELL="/bin/bash" \
  TERM="xterm" \
  mode="default" \
  var_brg="vmbr0" \
  var_cpu="4" \
  var_ctid="$container_id" \
  var_disk="32" \
  var_fuse="no" \
  var_hostname="controlplane" \
  var_ipv6_method="none" \
  var_keyctl="0" \
  var_mknod="0" \
  var_mount_fs="" \
  var_net="dhcp" \
  var_nesting="0" \
  var_os="$operating_system_id" \
  var_protection="no" \
  var_ram="4096" \
  var_tags="homelab-controlplane" \
  var_tun="no" \
  var_unprivileged="1" \
  var_version="$operating_system_version" \
  bash "$helper_path"

if ! pct status "$container_id" >/dev/null 2>&1; then
  fail "Community Scripts exited without creating container $container_id"
fi

# The current upstream builder enables keyctl for every unprivileged container
# even when var_keyctl=0. Homelab Control Plane requires no optional LXC
# features, so remove the complete upstream feature set before auditing it.
if pct config "$container_id" | grep -q '^features:'; then
  pct set "$container_id" --delete features >/dev/null
fi

pct set "$container_id" --onboot 1 --swap 1024 >/dev/null

container_configuration="$(pct config "$container_id")"

configuration_value() {
  local key="$1"
  sed -n "s/^${key}:[[:space:]]*//p" <<<"$container_configuration"
}

if ! grep -Eq '^unprivileged:[[:space:]]+1$' \
  <<<"$container_configuration"; then
  fail "container $container_id is not unprivileged; post-bootstrap validation failed"
fi

if [[ "$(configuration_value hostname)" != "controlplane" ]]; then
  fail "container $container_id has an unexpected hostname"
fi

if [[ "$(configuration_value cores)" != "4" ]]; then
  fail "container $container_id does not have the required 4 CPU cores"
fi

if [[ "$(configuration_value memory)" != "4096" ]]; then
  fail "container $container_id does not have the required 4096 MB RAM"
fi

if [[ "$(configuration_value swap)" != "1024" ]]; then
  fail "container $container_id does not have the required 1024 MB swap"
fi

if [[ "$(configuration_value onboot)" != "1" ]]; then
  fail "container $container_id is not configured to start at boot"
fi

root_filesystem="$(configuration_value rootfs)"
if [[ ",${root_filesystem}," != *",size=32G,"* ]]; then
  fail "container $container_id does not have the required 32 GB root disk"
fi

network_configuration="$(configuration_value net0)"
if [[ ",${network_configuration}," != *",bridge=vmbr0,"* ||
  ",${network_configuration}," != *",ip=dhcp,"* ]]; then
  fail "container $container_id does not use DHCP on vmbr0"
fi

if [[ ",${network_configuration}," == *",ip6="* ]]; then
  fail "container $container_id has an unexpected IPv6 bootstrap setting"
fi

features="$(configuration_value features)"
case ",${features}," in
  *,nesting=1,* | *,keyctl=1,* | *,fuse=1,* | *,mknod=1,*)
    fail "container $container_id has a forbidden LXC feature enabled"
    ;;
esac

if grep -Eq \
  '^(dev[0-9]+|mp[0-9]+|hookscript|lxc\.[^:]+):' \
  <<<"$container_configuration"; then
  fail "container $container_id has an unexpected mount, device, or AppArmor override"
fi

container_tags="$(configuration_value tags)"
case ";${container_tags};" in
  *";homelab-controlplane;"*)
    ;;
  *)
    fail "container $container_id is missing the homelab-controlplane tag"
    ;;
esac

if ! pct status "$container_id" | grep -q 'status: running'; then
  pct start "$container_id"
fi

detected_operating_system="$(
  pct exec "$container_id" -- sh -c \
    '. /etc/os-release; printf "%s:%s" "$ID" "$VERSION_ID"'
)"

expected_operating_system="${operating_system_id}:${operating_system_version}"
if [[ "$detected_operating_system" != "$expected_operating_system" ]]; then
  fail "container $container_id runs unexpected OS $detected_operating_system"
fi

cat <<EOF

Container ${container_id} was created successfully.

Next:
  1. Open container ${container_id} in the Proxmox web interface.
  2. Select Console.
  3. Follow the verified in-container installation instructions:
     ${PUBLIC_INSTALL_GUIDE}

Homelab Control Plane has not been installed on the Proxmox host.
EOF
