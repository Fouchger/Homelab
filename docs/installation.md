# Installation preview

The preview installation is one command. It creates an unprivileged Ubuntu
24.04 LXC, installs the signed Homelab Control Plane package inside it, starts
the HTTPS service, checks readiness, and prints the address to open.

It does not yet include the management dashboard or setup wizard.

## What you need

- a Proxmox VE host using an amd64 processor;
- root access to **Proxmox → your node → Shell**;
- storage for a 32 GB LXC disk;
- DHCP on the Proxmox management network;
- outbound HTTPS and working DNS.

The LXC receives 4 CPU cores, 4 GB RAM, 1 GB swap, and a 32 GB disk. It follows
the Proxmox default management route: an interface such as `vmbr0.20` becomes
bridge `vmbr0` with VLAN tag 20, while an untagged `vmbr0` remains untagged.
This places the control plane on the same network as Proxmox. When the host has
multiple suitable storage targets, the installer automatically uses the active
target with the most available space.

## Install

Open the Proxmox root shell and paste this one command:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fouchger/homelab/main/install.sh)"
```

Ubuntu 24.04 is the default. To use Debian 13 instead:

```bash
HOMELAB_OS=debian bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fouchger/homelab/main/install.sh)"
```

No other commands or interactive choices are required. On success, the final
output resembles:

```text
Homelab Control Plane 0.1.0 is installed and healthy.

Open: https://192.0.2.10:8443/

Automated installation completed successfully in container 100.
```

The preview uses a self-signed certificate, so the browser displays a warning.
Confirm that the address is the one printed by the installer before continuing.

## What the command does

The initial command trusts GitHub and HTTPS to deliver `install.sh`, in the
same way as other `curl | bash` installers. After that bootstrap, the script:

1. confirms it is running in the Proxmox root shell;
2. installs its own download and signature-verification tools;
3. downloads and verifies the signed LXC and application installers;
4. selects suitable template and container storage;
5. detects the Proxmox management bridge and VLAN;
6. creates and audits the unprivileged LXC with nesting enabled;
7. copies the verified application installer into the LXC;
8. verifies the signed release manifest and package digest;
9. installs and starts the package;
10. checks the local HTTPS readiness endpoint;
11. prints the dashboard URL.

After the application is installed, the bootstrap removes its downloaded
scripts, temporary state, and any temporary Community Scripts diagnostics file
it created. It does not remove Proxmox, networking, storage, or recovery tools.

Minisign is installed and used automatically. You do not need to install it or
run it yourself. It is retained because it prevents an altered release package
from passing verification after the initial HTTPS bootstrap.

## If installation fails

The installer preserves a newly created LXC when a later step fails and prints
its container ID, allowing inspection without losing the failure evidence.
Check the application from its console with:

```bash
systemctl status homelab-controlplane
journalctl -u homelab-controlplane --no-pager
curl --insecure https://127.0.0.1:8443/readyz
```

Rerunning the one-line command creates a new LXC. The application installer is
used only during initial provisioning and is removed afterward. Do not run a
generic `/root/install-controlplane.sh` from the LXC: Community Scripts may
place a different script at that path. Dashboard-initiated application updates
will use a separate, signed updater channel once that feature is enabled.
