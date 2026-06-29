#!/usr/bin/env bash
# it-tools LXC installer
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/JSisques/homelab-infra/main/ct/it-tools.sh)"

set -euo pipefail

# ─── Config ───────────────────────────────────────────
CT_ID=102
CT_NAME="it-tools"
CT_RAM=128
CT_CORES=1
CT_DISK=4
CT_IP="192.168.1.100/24"
CT_GW="192.168.1.1"
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"

# ─── Create LXC ───────────────────────────────────────
echo "Creating LXC ${CT_NAME}..."
pct create $CT_ID $TEMPLATE \
  --hostname $CT_NAME \
  --memory $CT_RAM \
  --cores $CT_CORES \
  --net0 name=eth0,bridge=vmbr0,ip=$CT_IP,gw=$CT_GW \
  --storage local-lvm \
  --rootfs local-lvm:${CT_DISK} \
  --unprivileged 1 \
  --start 1

sleep 5

# ─── Install it-tools ─────────────────────────────────
echo "Installing it-tools..."
pct exec $CT_ID -- bash -c "
  apt update -qq && apt install -y nginx curl unzip
  curl -fsSL https://github.com/CorentinTh/it-tools/releases/latest/download/it-tools.zip -o /tmp/it-tools.zip
  unzip -q /tmp/it-tools.zip -d /var/www/html
  systemctl enable --now nginx
"

echo "✓ it-tools available at http://${CT_IP%%/*}"
