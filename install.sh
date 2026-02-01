#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Phase 1: Validate prerequisites
info "Checking prerequisites..."

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (or with sudo)"
fi

if [[ ! -f config.local.yml ]]; then
    error "config.local.yml not found. Copy config.local.yml.example and customize it first."
fi

# Check for yq
if ! command -v yq &> /dev/null; then
    warn "yq not found, will install it"
fi

# Parse config values
INSTALL_BASE=$(yq -r '.install_base // "/opt/mediaserver"' config.local.yml)
MEDIA_PATH=$(yq -r '.media_path // "/data"' config.local.yml)
VPN_USER=$(yq -r '.vpn_user // "media-vpn"' config.local.yml)
MEDIA_GROUP=$(yq -r '.media_group // "media"' config.local.yml)

info "Configuration:"
info "  Install base: $INSTALL_BASE"
info "  Media path: $MEDIA_PATH"
info "  VPN user: $VPN_USER"
info "  Media group: $MEDIA_GROUP"

# Phase 2: Install system packages
info "Installing system packages..."

apt-get update
apt-get install -y \
    docker.io docker-compose \
    prometheus prometheus-alertmanager \
    prometheus-node-exporter prometheus-blackbox-exporter \
    yq ruby jq curl wget

# Phase 3: Create users and groups
info "Creating users and groups..."

groupadd -f "$MEDIA_GROUP"

if ! id "$VPN_USER" &>/dev/null; then
    useradd --system --create-home --shell /usr/sbin/nologin -g "$MEDIA_GROUP" "$VPN_USER"
    info "Created user $VPN_USER"
else
    info "User $VPN_USER already exists"
fi

usermod -aG docker "$VPN_USER"
usermod -aG "$MEDIA_GROUP" plex 2>/dev/null || warn "Could not add plex to $MEDIA_GROUP (plex user may not exist yet)"

# Enable lingering for user services at boot
loginctl enable-linger "$VPN_USER"

# Phase 4: Setup directories
info "Setting up directories..."

mkdir -p "$MEDIA_PATH"/{downloads,movies,tv,music}
chown -R root:"$MEDIA_GROUP" "$MEDIA_PATH"
chmod -R 775 "$MEDIA_PATH"

mkdir -p "$INSTALL_BASE"/config/{wireguard,radarr,sonarr,prowlarr,qbittorrent}
chown -R root:"$MEDIA_GROUP" "$INSTALL_BASE"
chmod -R 775 "$INSTALL_BASE"

# Phase 5: Generate and deploy configs
info "Generating configs..."

make clean && make all

info "Deploying configs..."

# Deploy docker-compose symlink
make deploy-compose

# Deploy user systemd unit
VPN_USER_HOME=$(eval echo "~$VPN_USER")
USER_SYSTEMD_DIR="$VPN_USER_HOME/.config/systemd/user"
mkdir -p "$USER_SYSTEMD_DIR"
cp systemd/user/media-stack.service "$USER_SYSTEMD_DIR/"
chown -R "$VPN_USER":"$MEDIA_GROUP" "$VPN_USER_HOME/.config"

# Phase 6: Enable services
info "Enabling services..."

# Enable user service
VPN_USER_UID=$(id -u "$VPN_USER")
sudo -u "$VPN_USER" XDG_RUNTIME_DIR="/run/user/$VPN_USER_UID" systemctl --user daemon-reload
sudo -u "$VPN_USER" XDG_RUNTIME_DIR="/run/user/$VPN_USER_UID" systemctl --user enable media-stack

# Enable Plex system service
systemctl enable plexmediaserver

info "Installation complete!"
echo ""
echo "Next steps:"
echo "1. Copy your WireGuard config to $INSTALL_BASE/config/wireguard/wg0.conf"
echo "2. Start the media stack:"
echo "   sudo -u $VPN_USER XDG_RUNTIME_DIR=/run/user/$VPN_USER_UID systemctl --user start media-stack"
echo "3. Access the services:"
echo "   - qBittorrent: http://localhost:8080"
echo "   - Radarr: http://localhost:7878"
echo "   - Sonarr: http://localhost:8989"
echo "   - Prowlarr: http://localhost:9696"
echo "   - Plex: http://localhost:32400/web"
