# Homelab Control Plane

[![Issues](https://img.shields.io/github/issues/Fouchger/homelab?label=issues)](https://github.com/Fouchger/homelab/issues)
[![Pull requests](https://img.shields.io/github/issues-pr/Fouchger/homelab?label=pull%20requests)](https://github.com/Fouchger/homelab/pulls)
[![Latest release](https://img.shields.io/github/v/release/Fouchger/homelab?include_prereleases&label=latest%20release)](https://github.com/Fouchger/homelab/releases)

Homelab Control Plane is a self-hosted appliance with a guided web dashboard
for managing supported Proxmox resources, Linux servers, network equipment, and
services.

The application runs inside an unprivileged Ubuntu or Debian LXC. An optional
signed host bootstrap invokes the third-party Community Scripts LXC creator;
the Homelab Control Plane application itself is installed only inside the LXC.

## Project status

The project is under development. The first published build is an installation
preview: it proves LXC creation, signed package installation, HTTPS startup,
and service readiness. It does not yet include the management dashboard or
setup wizard. Do not use preview releases on production infrastructure.

## Installation

Open the Proxmox root shell and run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Fouchger/homelab/main/install.sh)"
```

That command creates the LXC, installs the application inside it, checks the
service, and prints the HTTPS address. There are no interactive installation
steps. See the [installation guide](docs/installation.md) for requirements,
the Debian option, and troubleshooting.

Installable Debian packages, signed manifests, checksums, and software bills of
materials are published as versioned GitHub Release assets.

The application source and development history are maintained privately. This
public repository contains reviewed installation material, public
documentation, and signed binary releases.

## Security

Do not report vulnerabilities in a public issue. Follow the
[security policy](SECURITY.md).
