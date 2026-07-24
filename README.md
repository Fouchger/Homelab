# Homelab Control Plane

Homelab Control Plane is a self-hosted appliance with a guided web dashboard
for managing supported Proxmox resources, Linux servers, network equipment, and
services.

The application runs inside an unprivileged Ubuntu or Debian LXC. An optional
signed host bootstrap invokes the third-party Community Scripts LXC creator;
the Homelab Control Plane application itself is installed only inside the LXC.

## Project status

The project is under development. Do not use placeholder or test releases on
production infrastructure.

## Installation

Follow the [installation guide](docs/installation.md). Installable Debian
packages, signed manifests, checksums, and software bills of materials are
published as versioned GitHub Release assets.

The application source and development history are maintained privately. This
public repository contains reviewed installation material, public
documentation, and signed binary releases.

## Security

Do not report vulnerabilities in a public issue. Follow the
[security policy](SECURITY.md).
