#!/usr/bin/env bash
# headless.sh - Signal Proxy Hardened Provisioner (v14.2)
set -euo pipefail

# --- UI & Helpers ---
CYN=$'\x1b[0;36m'; GRN=$'\x1b[0;32m'; YLW=$'\x1b[0;33m'; RED=$'\x1b[0;31m'; RST=$'\x1b[0m'
log() { echo "${CYN}[$(date +%T)]${RST} $*"; }
ok()  { echo "${GRN}[+ ]${RST} $*"; }
die() { echo "${RED}[!]${RST} $*" >&2; exit 1; }

# --- Header ---
echo -e "${YLW}****************************************************************"
echo -e " SIGNAL PROXY PROVISIONER: HEADLESS MODE v14.2"
echo -e "****************************************************************${RST}"

# --- Config & State ---
STATE_FILE="/var/lib/vps-provision.state"
RUNTIME_FILE="/var/lib/vps-provision.vars"
[[ "${EUID}" -eq 0 ]] || die "Must be run as root (sudo -i)."

load_vars() { 
    [[ -f "$RUNTIME_FILE" ]] && source "$RUNTIME_FILE"
}

save_vars() {
    cat >"$RUNTIME_FILE" <<EOF
ADMIN_USER="$ADMIN_USER"
SSH_PORT="$SSH_PORT"
FQDN="$FQDN"
REPO_DIR="$REPO_DIR"
EOF
}

# --- Step Functions ---

step_1_system_upgrade_deps() {
    log "Performing full system upgrade (this ensures latest security patches)..."
    # Ensure no interactive prompts during upgrade
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade
    
    log "Installing base dependencies and Docker..."
    apt-get install -y ca-certificates curl gnupg git jq iptables-persistent netfilter-persistent dnsutils
    
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

step_2_collect_config() {
    log "Verifying Configuration..."

    # 1. ADMIN_USER - NO DEFAULTS
    if [[ -z "${ADMIN_USER:-}" ]]; then
        read -r -p "${YLW}[PROMPT]${RST} Enter Admin Username: " ADMIN_USER
    fi

    # 2. SSH_PORT - NO DEFAULTS
    if [[ -z "${SSH_PORT:-}" ]]; then
        read -r -p "${YLW}[PROMPT]${RST} Enter Target SSH Port: " SSH_PORT
    fi

    # 3. FQDN - NO DEFAULTS
    if [[ -z "${FQDN:-}" ]]; then
        read -r -p "${YLW}[PROMPT]${RST} Enter FQDN (e.g., signal.example.com): " FQDN
    fi

    # 4. SSH_PUBKEY - NO DEFAULTS
    if [[ -z "${SSH_PUBKEY:-}" ]]; then
        echo -e "${YLW}[PROMPT]${RST} Paste SSH Public Key (one line):"
        read -r SSH_PUBKEY
    fi

    REPO_DIR="/home/$ADMIN_USER/Signal-TLS-Proxy"

    echo -e "\n--- Deployment Configuration ---"
    echo "Admin User: $ADMIN_USER"
    echo "SSH Port:   $SSH_PORT"
    echo "FQDN:       $FQDN"
    echo "Repo Dir:   $REPO_DIR"
    echo -e "--------------------------------\n"
    
    save_vars
}

step_3_identity_ssh() {
    log "Configuring Identity and SSH..."
    
    if ! id "$ADMIN_USER" &>/dev/null; then
        adduser --gecos "" --disabled-password "$ADMIN_USER"
        echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/90-provisioner
        usermod -aG sudo,docker "$ADMIN_USER"
    fi

    local ssh_dir="/home/$ADMIN_USER/.ssh"
    mkdir -p "$ssh_dir" && chmod 700 "$ssh_dir"
    echo "$SSH_PUBKEY" > "$ssh_dir/authorized_keys"
    chown -R "$ADMIN_USER:$ADMIN_USER" "$ssh_dir"
    chmod 600 "$ssh_dir/authorized_keys"
}

step_4_repo_prep() {
    log "Preparing Repository..."
    if [[ ! -d "$REPO_DIR" ]]; then
        sudo -u "$ADMIN_USER" git clone https://github.com/signalapp/Signal-TLS-Proxy.git "$REPO_DIR"
    fi
}

step_5_firewall_stage() {
    log "Staging Firewall (Docker-safe)..."
    systemctl stop docker || true
    
    iptables -F && iptables -X && iptables -t nat -F
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p icmp -j ACCEPT
    iptables -A INPUT -p tcp -m multiport --dports 80,443,22,"$SSH_PORT" -j ACCEPT

    ip6tables -P INPUT DROP && ip6tables -P FORWARD DROP && ip6tables -P OUTPUT DROP
    
    systemctl start docker
}

step_6_cert_and_commit() {
    log "Running Certbot and Finalizing Deployment..."
    cd "$REPO_DIR"
    
    log "Waiting for DNS propagation for $FQDN..."
    local my_ip; my_ip=$(curl -s ifconfig.me)
    local count=0
    while [[ "$(dig +short "$FQDN" | tail -n1)" != "$my_ip" ]]; do
        echo -n "."
        sleep 10
        ((count++))
        [[ $count -gt 30 ]] && die "DNS failed to propagate to $my_ip after 5 mins."
    done
    echo ""

    ./init-certificate.sh
    
    log "Establishing SSH Safety Bridge..."
    cat > /etc/ssh/sshd_config.d/99-proxy.conf <<EOF
Port 22
Port $SSH_PORT
PasswordAuthentication no
EOF

    systemctl daemon-reload
    systemctl restart ssh.socket || systemctl restart ssh
    
    local confirm=""
    if [[ "${AUTO_COMMIT:-false}" == "true" ]]; then
        confirm="YES"
        log "AUTO_COMMIT detected. Finalizing lockdown..."
    else
        echo -e "${YLW}>>> BRIDGE ACTIVE. TEST NEW CONNECTION:${RST} ssh -p $SSH_PORT ${ADMIN_USER}@$(curl -s ifconfig.me)"
        read -r -p "Type 'YES' to COMMIT (drops port 22): " confirm
    fi
    
    if [[ "$confirm" == "YES" ]]; then
        cat > /etc/ssh/sshd_config.d/99-proxy.conf <<EOF
Port $SSH_PORT
PasswordAuthentication no
EOF
        systemctl daemon-reload
        systemctl restart ssh.socket || systemctl restart ssh
        
        iptables -D INPUT -p tcp -m multiport --dports 80,443,22,"$SSH_PORT" -j ACCEPT || true
        iptables -A INPUT -p tcp -m multiport --dports 80,443,"$SSH_PORT" -j ACCEPT
        netfilter-persistent save
        
        docker compose up -d
        ok "Provisioning complete! System is hardened on port $SSH_PORT."
    else
        die "Commit aborted. SSH remains in dual-listen mode."
    fi
}

# --- Main Dispatcher ---
load_vars
STAGES=("step_1_system_upgrade_deps" "step_2_collect_config" "step_3_identity_ssh" "step_4_repo_prep" "step_5_firewall_stage" "step_6_cert_and_commit")
CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

for i in "${!STAGES[@]}"; do
    if (( i >= CURRENT )); then
        ${STAGES[$i]}
        echo $((i + 1)) > "$STATE_FILE"
    fi
done
