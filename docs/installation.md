# Installation

## Availability

Homelab Control Plane has not published its first supported package yet. The
commands and signing key will appear here only after the end-to-end installer,
upgrade, backup, restore, and tamper tests pass.

Do not download an installer from an issue, comment, fork, or unofficial URL.

## Intended environment

The supported bootstrap runs in the Proxmox root shell and asks the user to
choose:

- Ubuntu 24.04 LTS, recommended; or
- Debian 13.

It invokes the corresponding third-party
[Community Scripts](https://community-scripts.org/categories?category=operating-systems)
LXC creator with a clean environment and controlled settings:

- 4 vCPU;
- 4 GB RAM;
- 1 GB swap;
- 32 GB disk;
- unprivileged mode;
- DHCP on `vmbr0`;
- no optional nesting, keyctl, FUSE, device, or mount features;
- outbound HTTPS access;
- start at boot.

The Community Scripts helper executes as Proxmox root and may retain its own
host-side defaults or logs. The Homelab Control Plane application installer
runs separately inside the LXC and does not install the application on the
host.

## Future verified installation

The supported procedure will:

1. download and verify the signed LXC bootstrap;
2. choose Ubuntu or Debian;
3. review and confirm the Community Scripts root execution;
4. validate the resulting Proxmox LXC configuration;
5. enter the new LXC;
6. download and verify the in-container installer;
7. verify the signed release manifest and Debian package checksum;
8. install and health-check the control-plane services;
9. display an HTTPS dashboard URL and short-lived setup code.

A copy-and-paste command is intentionally omitted until genuine signed release
artifacts exist.
