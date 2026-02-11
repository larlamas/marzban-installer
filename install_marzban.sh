#!/usr/bin/env bash
###############################################################################
#  Marzban — Custom Installation Script
#  ------------------------------------
#  Usage:
#    sudo bash install_marzban.sh <DOMAIN>
#
#  What it does:
#    1. Disables UFW (to avoid port-blocking issues)
#    2. Installs Docker (if not already installed)
#    3. Installs the official Marzban management CLI script
#    4. Downloads the official Marzban docker-compose.yml and xray config
#    5. Generates a random admin password and random HTTPS port
#    6. Writes the .env config with the provided domain
#    7. Installs Caddy as a reverse proxy with automatic TLS for the domain
#    8. Starts Marzban via Docker Compose
#    9. Prints credentials and the dashboard URL
#
#  Requirements: Ubuntu 20.04+ / Debian 11+, root privileges
###############################################################################
set -euo pipefail

# ─────────────────────── error handling ──────────────────────────────────────
trap 'echo ""; colorized_echo red "ERROR: Script failed at line $LINENO (exit code $?)"; echo "Run with: bash -x install_marzban.sh <DOMAIN> for debug output"; exit 1' ERR

# ─────────────────────── colour helpers ──────────────────────────────────────
colorized_echo() {
    local color="$1"
    local text="$2"
    case "$color" in
        red)     printf "\e[91m%s\e[0m\n" "$text" ;;
        green)   printf "\e[92m%s\e[0m\n" "$text" ;;
        yellow)  printf "\e[93m%s\e[0m\n" "$text" ;;
        blue)    printf "\e[94m%s\e[0m\n" "$text" ;;
        magenta) printf "\e[95m%s\e[0m\n" "$text" ;;
        cyan)    printf "\e[96m%s\e[0m\n" "$text" ;;
        *)       echo "$text" ;;
    esac
}

# ─────────────────────── banner ──────────────────────────────────────────────
print_banner() {
    echo ""
    colorized_echo cyan "╔══════════════════════════════════════════════════╗"
    colorized_echo cyan "║       MARZBAN — Custom Installer Script         ║"
    colorized_echo cyan "╚══════════════════════════════════════════════════╝"
    echo ""
}

# ─────────────────────── pre-flight checks ───────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        colorized_echo red "Error: This script must be run as root (use sudo)."
        exit 1
    fi
}

check_os() {
    if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
        colorized_echo yellow "Warning: This script is designed for Ubuntu/Debian. Proceeding anyway..."
    fi
}

# ─────────────────────── variables ───────────────────────────────────────────
APP_NAME="marzban"
INSTALL_DIR="/opt"
APP_DIR="${INSTALL_DIR}/${APP_NAME}"
DATA_DIR="/var/lib/${APP_NAME}"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
FILES_URL_PREFIX="https://raw.githubusercontent.com/Gozargah/Marzban/master"
MARZBAN_SCRIPT_REPO="Gozargah/Marzban-scripts"
MARZBAN_SCRIPT_URL="https://github.com/${MARZBAN_SCRIPT_REPO}/raw/master/marzban.sh"

# Random HTTPS port in the ephemeral range (avoids conflicts with well-known ports)
HTTPS_PORT=$(shuf -i 50000-65535 -n1)

# Random credentials
ADMIN_USER="admin"
ADMIN_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
ACME_EMAIL=$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)

# Caddy version
CADDY_VERSION="2.9.1"
CADDY_DEB_URL="https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.deb"

# ─────────────────────── domain handling ─────────────────────────────────────
get_domain() {
    if [[ -n "${1:-}" ]]; then
        DOMAIN="$1"
    else
        colorized_echo yellow "No domain was passed as an argument."
        read -rp "$(colorized_echo cyan 'Enter the domain for the Marzban panel (e.g. panel.example.com): ')" DOMAIN
    fi

    if [[ -z "$DOMAIN" ]]; then
        colorized_echo red "Error: Domain cannot be empty."
        exit 1
    fi

    # Basic domain format validation
    if ! echo "$DOMAIN" | grep -qP '^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)+$'; then
        colorized_echo red "Error: '${DOMAIN}' does not look like a valid domain name."
        exit 1
    fi

    colorized_echo green "Domain set to: ${DOMAIN}"
}

# ─────────────────────── firewall ────────────────────────────────────────────
configure_firewall() {
    colorized_echo blue "[1/7] Configuring firewall..."
    if command -v ufw &>/dev/null; then
        ufw disable || true
        colorized_echo green "UFW disabled."
    else
        colorized_echo yellow "UFW not found — skipping."
    fi
}

# ─────────────────────── Docker ──────────────────────────────────────────────
install_docker() {
    colorized_echo blue "[2/7] Installing Docker..."
    if command -v docker &>/dev/null; then
        colorized_echo green "Docker is already installed — skipping."
    else
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
        colorized_echo green "Docker installed and started."
    fi
}

# ─────────────────────── Marzban CLI ─────────────────────────────────────────
install_marzban_cli() {
    colorized_echo blue "[3/7] Installing Marzban CLI script..."
    curl -sSL "$MARZBAN_SCRIPT_URL" | install -m 755 /dev/stdin /usr/local/bin/marzban
    colorized_echo green "Marzban CLI installed → /usr/local/bin/marzban"
}

# ─────────────────────── Marzban files ───────────────────────────────────────
download_marzban_files() {
    colorized_echo blue "[4/7] Downloading Marzban configuration files..."

    mkdir -p "$APP_DIR"
    mkdir -p "$DATA_DIR"

    # docker-compose.yml
    curl -sSL "${FILES_URL_PREFIX}/docker-compose.yml" -o "$COMPOSE_FILE"
    colorized_echo green "  ✓ docker-compose.yml → ${COMPOSE_FILE}"

    # xray config
    curl -sSL "${FILES_URL_PREFIX}/xray_config.json" -o "${DATA_DIR}/xray_config.json"
    colorized_echo green "  ✓ xray_config.json  → ${DATA_DIR}/xray_config.json"
}

# ─────────────────────── .env ────────────────────────────────────────────────
generate_env() {
    colorized_echo blue "[5/7] Generating .env configuration..."

    cat > "${APP_DIR}/.env" <<EOF
# ── Marzban Environment ───────────────────────────────────────
UVICORN_HOST = "127.0.0.1"
UVICORN_PORT = 8000
SUDO_USERNAME = "${ADMIN_USER}"
SUDO_PASSWORD = "${ADMIN_PASS}"
XRAY_JSON = "/var/lib/marzban/xray_config.json"
SQLALCHEMY_DATABASE_URL = "sqlite:////var/lib/marzban/db.sqlite3"
XRAY_SUBSCRIPTION_URL_PREFIX = "https://${DOMAIN}:${HTTPS_PORT}"
EOF

    colorized_echo green "  ✓ .env → ${APP_DIR}/.env"
}

# ─────────────────────── Caddy ───────────────────────────────────────────────
install_caddy() {
    colorized_echo blue "[6/7] Installing & configuring Caddy reverse proxy..."

    # Install Caddy from .deb
    local tmp_deb="/tmp/caddy_${CADDY_VERSION}.deb"
    curl -sSL "$CADDY_DEB_URL" -o "$tmp_deb"
    dpkg -i "$tmp_deb"
    rm -f "$tmp_deb"

    colorized_echo green "  ✓ Caddy v${CADDY_VERSION} installed"

    # Write Caddyfile
    cat > /etc/caddy/Caddyfile <<CADDYEOF
{
    auto_https disable_redirects
    https_port ${HTTPS_PORT}
    log {
        level ERROR
    }
    on_demand_tls {
        ask http://localhost:10087/
        interval 3600s
        burst 4
    }
}

# Handle connections by IP (self-signed TLS)
https://{\$IP}:${HTTPS_PORT} {
    reverse_proxy localhost:8000
    tls internal {
        on_demand
    }
}

# Handle connections by domain (automatic Let's Encrypt TLS)
https://*.*:${HTTPS_PORT},
https://*.*.*:${HTTPS_PORT} {
    reverse_proxy localhost:8000
    tls {
        on_demand
        issuer acme {
            email ${ACME_EMAIL}@noreply.local
        }
    }
}

# Internal responder for on_demand_tls ask endpoint
http://:10087 {
    respond "allowed" 200 {
        close
    }
}
CADDYEOF

    systemctl restart caddy
    colorized_echo green "  ✓ Caddy configured and restarted"
}

# ─────────────────────── start Marzban ───────────────────────────────────────
start_marzban() {
    colorized_echo blue "[7/7] Starting Marzban..."
    docker compose -f "$COMPOSE_FILE" -p "$APP_NAME" up -d --remove-orphans
    colorized_echo green "Marzban containers are up and running!"
}

# ─────────────────────── summary ─────────────────────────────────────────────
print_summary() {
    echo ""
    colorized_echo cyan "╔══════════════════════════════════════════════════╗"
    colorized_echo cyan "║            Installation Complete!                ║"
    colorized_echo cyan "╠══════════════════════════════════════════════════╣"
    echo ""
    colorized_echo green "  Dashboard URL : https://${DOMAIN}:${HTTPS_PORT}/dashboard/"
    echo ""
    colorized_echo green "  Username      : ${ADMIN_USER}"
    colorized_echo green "  Password      : ${ADMIN_PASS}"
    echo ""
    colorized_echo green "  HTTPS Port    : ${HTTPS_PORT}"
    echo ""
    colorized_echo cyan "╠══════════════════════════════════════════════════╣"
    colorized_echo yellow "  Useful commands:"
    colorized_echo yellow "    marzban logs          — view logs"
    colorized_echo yellow "    marzban restart       — restart Marzban"
    colorized_echo yellow "    marzban update        — update to latest"
    colorized_echo yellow "    marzban cli admin create --sudo  — new admin"
    echo ""
    colorized_echo cyan "╠══════════════════════════════════════════════════╣"
    colorized_echo yellow "  Config files:"
    colorized_echo yellow "    ${APP_DIR}/.env"
    colorized_echo yellow "    ${APP_DIR}/docker-compose.yml"
    colorized_echo yellow "    ${DATA_DIR}/xray_config.json"
    colorized_echo yellow "    /etc/caddy/Caddyfile"
    colorized_echo cyan "╚══════════════════════════════════════════════════╝"
    echo ""
}

# ─────────────────────── main ────────────────────────────────────────────────
main() {
    print_banner
    check_root
    check_os

    # When run via: bash -c "$(wget -qO- ...)" mydomain.com
    # the domain lands in $0 (not $1). Detect this and fix it.
    local domain_arg="${1:-}"
    if [[ -z "$domain_arg" ]] && [[ "$0" == *.* ]] && [[ "$0" != */* ]] && [[ "$0" != "bash" ]] && [[ "$0" != "-bash" ]]; then
        domain_arg="$0"
    fi

    get_domain "$domain_arg"

    configure_firewall
    install_docker
    install_marzban_cli
    download_marzban_files
    generate_env
    install_caddy
    start_marzban
    print_summary
}

main "$@"

