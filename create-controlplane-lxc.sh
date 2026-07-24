#!/usr/bin/env bash

set -Eeuo pipefail

readonly COMMUNITY_SCRIPTS_REPOSITORY="community-scripts/ProxmoxVE"
readonly COMMUNITY_SCRIPTS_BASE_URL="https://raw.githubusercontent.com/${COMMUNITY_SCRIPTS_REPOSITORY}/main/ct"
readonly PUBLIC_INSTALL_GUIDE="https://github.com/Fouchger/homelab/blob/main/docs/installation.md"

cleanup_directory=""
non_interactive="false"
requested_operating_system=""
template_storage=""
container_storage=""
output_id_file=""
network_bridge="vmbr0"
network_vlan=""
created_diagnostics_file=""
created_diagnostics_directory=""

cleanup() {
  if [[ -n "$created_diagnostics_file" &&
    -f "$created_diagnostics_file" ]]; then
    rm -f -- "$created_diagnostics_file"
  fi
  if [[ -n "$created_diagnostics_directory" &&
    -d "$created_diagnostics_directory" ]]; then
    rmdir -- "$created_diagnostics_directory" 2>/dev/null || true
  fi
  if [[ -n "$cleanup_directory" && -d "$cleanup_directory" ]]; then
    rm -rf -- "$cleanup_directory"
  fi
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

trap cleanup EXIT

while (($#)); do
  case "$1" in
    --non-interactive)
      non_interactive="true"
      shift
      ;;
    --os)
      [[ $# -ge 2 ]] || fail "--os requires ubuntu or debian"
      requested_operating_system="$2"
      shift 2
      ;;
    --template-storage)
      [[ $# -ge 2 ]] || fail "--template-storage requires a storage name"
      template_storage="$2"
      shift 2
      ;;
    --container-storage)
      [[ $# -ge 2 ]] || fail "--container-storage requires a storage name"
      container_storage="$2"
      shift 2
      ;;
    --output-id-file)
      [[ $# -ge 2 ]] || fail "--output-id-file requires a path"
      output_id_file="$2"
      shift 2
      ;;
    --bridge)
      [[ $# -ge 2 ]] || fail "--bridge requires a Proxmox bridge name"
      network_bridge="$2"
      shift 2
      ;;
    --vlan)
      [[ $# -ge 2 ]] || fail "--vlan requires a VLAN ID"
      network_vlan="$2"
      shift 2
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ "$network_bridge" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail "invalid Proxmox bridge name: $network_bridge"
if [[ -n "$network_vlan" ]] &&
  { [[ ! "$network_vlan" =~ ^[0-9]+$ ]] ||
    ((network_vlan < 1 || network_vlan > 4094)); }; then
  fail "VLAN ID must be between 1 and 4094"
fi
for storage_name in "$template_storage" "$container_storage"; do
  if [[ -n "$storage_name" &&
    ! "$storage_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "invalid Proxmox storage name: $storage_name"
  fi
done
if [[ "$non_interactive" == "true" && -z "$requested_operating_system" ]]; then
  requested_operating_system="ubuntu"
fi

if [[ "${EUID}" -ne 0 ]]; then
  fail "run this bootstrap as root in the Proxmox VE shell"
fi

for command_name in pveversion pvesh pct curl sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "required Proxmox command is missing: $command_name"
done
ip link show dev "$network_bridge" >/dev/null 2>&1 ||
  fail "network bridge does not exist: $network_bridge"
[[ -d "/sys/class/net/${network_bridge}/bridge" ]] ||
  fail "network device is not a Linux bridge: $network_bridge"

architecture="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$architecture" in
  amd64 | x86_64)
    ;;
  *)
    fail "the first Homelab Control Plane package supports amd64 only; detected $architecture"
    ;;
esac

if [[ "$non_interactive" != "true" ]]; then
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
fi

while true; do
  if [[ -n "$requested_operating_system" ]]; then
    operating_system_choice="$requested_operating_system"
  else
    read -r -p "Selection [1]: " operating_system_choice
    operating_system_choice="${operating_system_choice:-1}"
  fi

  case "$operating_system_choice" in
    1 | ubuntu)
      operating_system_name="Ubuntu 24.04 LTS"
      operating_system_id="ubuntu"
      operating_system_version="24.04"
      helper_url="${COMMUNITY_SCRIPTS_BASE_URL}/ubuntu.sh"
      break
      ;;
    2 | debian)
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
      if [[ -n "$requested_operating_system" ]]; then
        fail "--os must be ubuntu or debian"
      fi
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
vlan_summary="${network_vlan:-untagged}"

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
  Network:  DHCP on ${network_bridge}
  VLAN:     ${vlan_summary}
  Template: ${template_storage:-selected by upstream}
  Storage:  ${container_storage:-selected by upstream}
  Type:     Unprivileged
  Nesting:  Disabled

The wrapper forces the upstream helper's Default mode. No unapproved var_*
values from your shell are passed into the helper.
EOF

if [[ "$non_interactive" == "true" ]]; then
  printf '\nAutomated installation requested; creating the reviewed default LXC.\n'
  if [[ ! -e /usr/local/community-scripts/diagnostics ]]; then
    if [[ ! -d /usr/local/community-scripts ]]; then
      install -d -m 0755 /usr/local/community-scripts
      created_diagnostics_directory="/usr/local/community-scripts"
    fi
    created_diagnostics_file="/usr/local/community-scripts/diagnostics"
    printf 'DIAGNOSTICS=no\n' \
      > "$created_diagnostics_file"
    chmod 0644 "$created_diagnostics_file"
  fi
else
  printf '\nType RUN to execute this third-party script as root on Proxmox.\n'
  read -r -p "Confirmation: " confirmation
  if [[ "$confirmation" != "RUN" ]]; then
    printf 'Cancelled. No container was created.\n'
    exit 0
  fi
fi

clean_environment=(
  HOME="/root"
  LANG="C.UTF-8"
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  SHELL="/bin/bash"
  TERM="xterm"
  mode="default"
  var_brg="$network_bridge"
  var_cpu="4"
  var_ctid="$container_id"
  var_disk="32"
  var_fuse="no"
  var_hostname="controlplane"
  var_ipv6_method="none"
  var_keyctl="0"
  var_mknod="0"
  var_mount_fs=""
  var_net="dhcp"
  var_nesting="1"
  var_os="$operating_system_id"
  var_protection="no"
  var_ram="4096"
  var_tags="homelab-controlplane"
  var_tun="no"
  var_unprivileged="1"
  var_version="$operating_system_version"
)
if [[ -n "$template_storage" ]]; then
  clean_environment+=("var_template_storage=$template_storage")
fi
if [[ -n "$container_storage" ]]; then
  clean_environment+=("var_container_storage=$container_storage")
fi
if [[ -n "$network_vlan" ]]; then
  clean_environment+=("var_vlan=$network_vlan")
fi
if [[ "$non_interactive" == "true" ]]; then
  clean_environment+=("PHS_SILENT=1")
fi
env -i "${clean_environment[@]}" bash "$helper_path"

if ! pct status "$container_id" >/dev/null 2>&1; then
  fail "Community Scripts exited without creating container $container_id"
fi

# The current upstream builder enables keyctl for every unprivileged container
# even when var_keyctl=0. Remove the complete upstream feature set, then restore
# only nesting, which is explicitly required by this appliance.
if pct config "$container_id" | grep -q '^features:'; then
  pct set "$container_id" --delete features >/dev/null
fi
pct set "$container_id" --features nesting=1 >/dev/null

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
if [[ ",${network_configuration}," != *",bridge=${network_bridge},"* ||
  ",${network_configuration}," != *",ip=dhcp,"* ]]; then
  fail "container $container_id does not use DHCP on $network_bridge"
fi
if [[ -n "$network_vlan" ]]; then
  if [[ ",${network_configuration}," != *",tag=${network_vlan},"* ]]; then
    fail "container $container_id is not tagged for VLAN $network_vlan"
  fi
elif [[ ",${network_configuration}," == *",tag="* ]]; then
  fail "container $container_id has an unexpected VLAN tag"
fi

if [[ ",${network_configuration}," == *",ip6="* ]]; then
  fail "container $container_id has an unexpected IPv6 bootstrap setting"
fi

features="$(configuration_value features)"
case ",${features}," in
  *,keyctl=1,* | *,fuse=1,* | *,mknod=1,*)
    fail "container $container_id has a forbidden LXC feature enabled"
    ;;
esac
case ",${features}," in
  *,nesting=1,*)
    ;;
  *)
    fail "container $container_id is missing the required nesting feature"
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
  # The variables expand inside the container, not in this host shell.
  # shellcheck disable=SC2016
  pct exec "$container_id" -- sh -c \
    '. /etc/os-release; printf "%s:%s" "$ID" "$VERSION_ID"'
)"

expected_operating_system="${operating_system_id}:${operating_system_version}"
if [[ "$detected_operating_system" != "$expected_operating_system" ]]; then
  fail "container $container_id runs unexpected OS $detected_operating_system"
fi

if [[ -n "$output_id_file" ]]; then
  printf '%s\n' "$container_id" > "$output_id_file"
  chmod 0600 "$output_id_file"
fi

if [[ "$non_interactive" == "true" ]]; then
  cat <<EOF

Container ${container_id} was created and audited successfully.
Continuing with the automated in-container application installation.
EOF
else
  cat <<EOF

Container ${container_id} was created successfully.

Next:
  1. Open container ${container_id} in the Proxmox web interface.
  2. Select Console.
  3. Follow the verified in-container installation instructions:
     ${PUBLIC_INSTALL_GUIDE}

Homelab Control Plane has not been installed on the Proxmox host.
EOF
fi
