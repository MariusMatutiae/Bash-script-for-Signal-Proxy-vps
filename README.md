# Signal Proxy Provisioner (Ubuntu 24.04 optimized)

![Signal](https://img.shields.io/badge/Signal-Proxy-blue?logo=signal&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-E95420?logo=ubuntp&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-required-2496ED?logo=docker&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)

A surgical bash script designed to deploy a **Signal TLS Proxy** with zero-lockout SSH migration and "Docker-safe" firewalling.

## Why this exists
Most automated provisioning scripts fail on Ubuntu 24.04 due to the new `systemd` socket activation for SSH. This script implements a **"Safety Bridge" philosophy**: it never closes the old SSH port until you have confirmed the new one is functional.

### Key Features
* **Zero-Lockout SSH Migration:** Implements a dual-listening "Safety Bridge" (Port 22 + Custom Port) during setup.
* **Ubuntu 24.04 Socket-Aware:** Correctly handles `ssh.socket` to ensure port changes persist across reboots.
* **Docker-Safe Firewalling:** Intelligently sequences rules so Docker doesn't bypass your security policy.
* **Hardened by Default:** Drops IPv6, disables passwords, and sets a default `DROP` policy on IPv4.

## Deployment Modes
The script is designed to be flexible. You can provide configuration upfront for automation or let the script guide you.

### 1. The One-Liner (Recommended)
Pass variables directly on the same line to trigger a fully automated install:
```bash
sudo ADMIN_USER=john SSH_PORT=55555 FQDN=signal.example.com AUTO_COMMIT=true SSH_PUBKEY="ssh-rsa ..." bash headless.sh 
```

### 2. Using Export
If you are deploying multiple machines in one session, you can export the variables first:

```bash
export SSH_PUBKEY="your-key-here"
export ADMIN_USER="proxyadmin"
sudo -E bash headless.sh
```

**Note:** Use **sudo -E** to ensure your exported variables are passed throug


### 3. Interactive Mode
If the script detects that a required variable (like SSH_PORT or FQDN) is missing from the environment, it will **pause and prompt you** with a visible `[PROMPT]` message. It will never use "hidden" defaults, ensuring you are always in control of the configuration.

## Note
The script will keep Port 22 open alongside your new port. **Do not close your current terminal window** until you have verified you can log in through the new port in a second window!

> [!IMPORTANT]
> **Security Architecture: Passwordless Operation**
> To maximize hardening, this script creates the admin user with `--disabled-password`. 
> - **Login:** Access is strictly limited to the provided SSH Public Key. 
> - **Privileges:** The user is granted `NOPASSWD` sudo rights to allow for non-interactive system management and Docker operations. 
> - **Result:** There are no user passwords on the system to be brute-forced.


**Pro-Tip: Web Console Access**
Since this script disables passwords for maximum security, the provider's "Web Console" will not be accessible for login. In an emergency (e.g., loss of SSH keys), you must use the provider's 'Rescue Mode' to mount the disk and manually set a password or replace the authorized_keys file.

## Troubleshooting
* **SSH Socket Issues:** If port changes don't show up in `ss -lntp`, the script automatically triggers `systemctl restart ssh.socket`.
* **Certbot Failures:** Ensure Port 80 is not blocked by your VPS provider's external dashboard (security groups).
* **Logs:** Check container status with `docker compose ps` in the repository directory.
* **Docker Firewall Conflicts**: If you manually change firewall rules while Docker is running, Docker might bypass them. Always let the script handle the rule staging by stopping Docker first.

## Maintenance
The script tracks its progress in `/var/lib/vps-provision.state`. If it fails, fix the issue and run it again; it will skip the completed steps.

