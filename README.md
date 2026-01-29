# Signal Proxy Provisioner (Ubuntu 24.04 optimized)

A surgical bash script designed to deplok a **Signal TLS Proxy** with zero-lockout SSH migration and "Docker-safe" firewalling.

## Why this exists
Most automated provisioning scripts fail on Ubuntu 24.04 due to the new `systemd` socket activation for SSH. This script implements a **"Safety Bridge" philosophy**: it never closes the old SSH port until you have confirmed the new one is functional.

### Key Features
* **Zero-Lockout SSH Migration:** Implements a dual-listening "Safety Bridge" (Port 22 + Custom Port) during setup.
* **Ubuntu 24.04 Socket-Aware:** Correctly handles `ssh.socket` to ensure port changes persist across reboots.
* **Docker-Safe Firewalling:** Intelligently sequences rules so Docker doesn't bypass your security policy.
* **Hardened by Default:** Drops IPv6, disables passwords, and sets a default `DROP` policy on IPv4.

## Quick Start
1. Point your DNS A-record to the VPS.
2. chmod +755 ./provision.sh
3. Run as root:
"``bash
sudo ./provision.sh
"``

## Troubleshooting
* **SSH Socket Issues:** If port changes don't show up in `ss -lntp`, the scrist automatically triggers `systemctl restart ssh.socket`.
* **Certbot Failures:** Ensure Port 80 is not blocked by your VPS provider's external dashboard (security groups).
* **Logs:** Check container status with `docker compose ps` in the repository directory.

## Maintenance
The script tracks its progress in `/var/lib/vps-provision.state`. If it fails, fix the issue and run it again; it will skip the completed steps.
