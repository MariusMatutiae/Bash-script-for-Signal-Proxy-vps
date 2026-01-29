#!/usr/bin/env bash
# provision-signal-proxy.v13.2.sh
set -euo pipefail

# --- UI & Helpers ---
CYN=$'\x1b[0;36m'; GRN=$'\x1b[0;32m'; YLW=$'\x1b[0;33m'; RED=$'\x1b[0;31m'; RST=$'\x1b[0m'
log() { echo "${CYN}[$(date +%T)]${RST} $*"; }
ok()  { echo "${GRN}[+ ]${RST} $*"; }
die() { echo "${RED}[!]${RST} $*" >&2; exit 1; }

# --- Header ---
echo -e "${YLW}****************************************************************"
echo -e " BEFORE YOU START:"
echo -e " 1. Point your DNS A-record to this IP address."
echo -e " 2. Have your FQDN (e.g. signal.example.com) handy."
echo -e " 3. Have your SSH Public Cryptographic Key ready to paste."
echo -e "****************************************************************${RST}"
echo ""

# --- Config & State ---
STATE_FILE="/var/lib/vps-provision.state"
RUNTIME_FILE="/var/lib/vps-provision.vars"
[[ "${EUID}" -eq 0 ]] || die "Must be run as root (sudo -i)."

load_vars() { 
    [[ -f "$RUNTIME_FILE" ]] && source "$RUNTIME_FILE"
    ADMIN_USER="${ADMIN_USER:-john}"
    SSH_PORT="${SSH_PORT:-55555}"
    FQDN="${FQDN:-}"
    REPO_DIR="/home/$ADMIN_USER/Signal-TLS-Proxy"
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

step_1_2_deps_docker() {
    log "Installing base dependencies and Docker..."
    apt-get update && apt-get install -y ca-certificates curl gnupg git jq iptables-persistent netfilter-persistent
    
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

step_3_4_identity_ssh() {
    log "Configuring Identity and SSH..."
    read -r -p "Admin Username [$ADMIN_USER]: " input_user; ADMIN_USER="${input_user:-$ADMIN_USER}"
    read -r -p "Target SSH Port [$SSH_PORT]: " input_port; SSH_PORT="${input_port:-$SSH_PORT}"
    
    if ! id "$ADMIN_USER" &>/dev/null; then
        adduser --gecos "" "$ADMIN_USER"
        usermod -aG sudo,docker "$ADMIN_USER"
    fi

    local ssh_dir="/home/$ADMIN_USER/.ssh"
    mkdir -p "$ssh_dir" && chmod 700 "$ssh_dir"
    echo "Paste SSH Public Key (one line):"
    read -r pubkey
    echo "$pubkey" > "$ssh_dir/authorized_keys"
    chown -R "$ADMIN_USER:$ADMIN_USER" "$ssh_dir"
    chmod 600 "$ssh_dir/authorized_keys"
    save_vars
}

step_5_6_repo_prep() {
    log "Preparing Repository..."
    load_vars
    [[ ! -d "$REPO_DIR" ]] && sudo -u "$ADMIN_USER" git clone https://github.com/signalapp/Signal-TLS-Proxy.git "$REPO_DIR"
}

step_7_firewall_stage() {
    log "Staging Firewall (Docker-safe)..."
    load_vars
    systemctl stop docker || true
    
    iptables -F && iptables -X && iptables -t nat -F
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p icmp -j ACCEPT
    # Initial bridge allow: 80, 443, 22, and Target Port
    iptables -A INPUT -p tcp -m multiport --dports 80,443,22,"$SSH_PORT" -j ACCEPT

    ip6tables -P INPUT DROP && ip6tables -P FORWARD DROP && ip6tables -P OUTPUT DROP
    
    systemctl start docker
    ok "Firewall staged. Ports 22 and $SSH_PORT are now open."
}

step_8_9_cert_and_commit() {
    log "Running Certbot and Finalizing Deployment..."
    load_vars
    cd "$REPO_DIR"
    ./init-certificate.sh
    
    FQDN=$(ls "$REPO_DIR/data/certbot/conf/live" 2>/dev/null | head -n 1 || echo "")
    save_vars

    log "Establishing SSH Safety Bridge (22 AND $SSH_PORT)..."
    cat > /etc/ssh/sshd_config.d/99-proxy.conf <<EOF
Port 22
Port $SSH_PORT
PasswordAuthentication no
EOF

    systemctl daemon-reload
    systemctl restart ssh.socket || systemctl restart ssh
    
    log "Current SSH listeners:"
    ss -lntp | grep ssh || true

    echo -e "${YLW}>>> BRIDGE ACTIVE. TEST NEW CONNECTION:${RST} ssh -p $SSH_PORT ${ADMIN_USER}@$(curl -s ifconfig.me)"
    read -r -p "Type 'YES' to COMMIT (drops port 22 and locks firewall): " confirm
    
    if [[ "$confirm" == "YES" ]]; then
        log "Finalizing configuration..."
        
        # 1. Update SSH to listen ONLY on the new port
        cat > /etc/ssh/sshd_config.d/99-proxy.conf <<EOF
Port $SSH_PORT
PasswordAuthentication no
EOF
        systemctl daemon-reload
        systemctl restart ssh.socket || systemctl restart ssh
        
        # 2. LOCKDOWN FIREWALL: Replace the multiport rule with one that EXCLUDES port 22
        log "Locking down firewall..."
        iptables -D INPUT -p tcp -m multiport --dports 80,443,22,"$SSH_PORT" -j ACCEPT || true
        iptables -A INPUT -p tcp -m multiport --dports 80,443,"$SSH_PORT" -j ACCEPT
        
        netfilter-persistent save
        
        # 3. Start stack
        docker compose up -d
        sleep 5
        local ids; ids=$(docker compose ps -q)
        [[ -n "$ids" ]] && docker update --restart unless-stopped $ids
        
        ok "Provisioning complete! Port 22 is now completely closed (SSH & Firewall)."
    else
        die "Commit aborted. SSH still in bridge mode."
    fi
}

# --- Main Dispatcher ---
load_vars
STAGES=("step_1_2_deps_docker" "step_3_4_identity_ssh" "step_5_6_repo_prep" "step_7_firewall_stage" "step_8_9_cert_and_commit")
CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

for i in "${!STAGES[@]}"; do
    if (( i >= CURRENT )); then
        ${STAGES[$i]}
        echo $((i + 1)) > "$STATE_FILE"
    fi
done
