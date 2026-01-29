# Signal Proxy Provisioner (Ubuntu 24.04 optimized)

A surgical bash script designed to deploy a **Signal TLS Proxy** with zero-lockout SSH migration and "Docker-safe" firewalling.

## Why this exists
Most automated provisioning scripts fail on Ubuntu 24.04 due to the new `systemd` socket activation for SSH. This script implements a **"Safety Bridge" philosophy**: it never closes the old SSH port until you have confirmed the new one is functional.

### Key Features
* **Zero-Lockout SSH Migration (keeps Port 22 open until you've successfully logged in on the new port).":** Implements a dual-listening "Safety Bridge" (Port 22 + Custom Port) during setup.
* **Ubuntu 24.04 Socket-Aware:** Correctly handles `ssh.socket` to ensure port changes persist across reboots.
* **Docker-Safe Firewalling:** Intelligently sequences rules so Docker doesn't bypass your security policy.
* **Hardened by Default:** Drops IPv6, disables passwords, and sets a default `DROP` policy on IPv4.

## Quick Start
1. Point your DNS A-record to the VPS.
2. Run the one-liner as root to install automatically:
```bash
wget -qO provision.sh https://raw.githubusercontent.com/MariusMatutiae/Bash-script-for-Signal-Proxy-vps/main/provision.sh && chmod +x provision.sh && sudo ./provision.sh
```
## Note
The script will keep Port 22 open alongside your new port. **Do not close your current terminal window** until you have verified you can log in through the new port in a second window!

## Troubleshooting
* **SSH Socket Issues:** If port changes don't show up in `ss -lntp`, the script automatically triggers `systemctl restart ssh.socket`.
* **Certbot Failures:** Ensure Port 80 is not blocked by your VPS provider's external dashboard (security groups).
* **Logs:** Check container status with `docker compose ps` in the repository directory.
* **Docker Firewall Conflicts**: If you manually change firewall rules while Docker is running, Docker might bypass them. Always let the script handle the rule staging by stopping Docker first.

## Maintenance
The script tracks its progress in `/var/lib/vps-provision.state`. If it fails, fix the issue and run it again; it will skip the completed steps.
