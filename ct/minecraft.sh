#!/usr/bin/env bash
#
# create-papermc-lxc.sh
# ----------------------------------------------------------------------------
# Run this on the PROXMOX NODE SHELL (not inside an LXC).
# Creates a Debian 12 LXC and installs Java + PaperMC (latest stable version)
# inside it, with a systemd service, ready to run.
#
# Usage:
#   chmod +x create-papermc-lxc.sh
#   ./create-papermc-lxc.sh
# ----------------------------------------------------------------------------

set -euo pipefail

### ==================== CONFIGURATION (edit as needed) ====================
CTID=""                        # Empty = auto-detect the next free ID (pvesh get /cluster/nextid). Set a number here to force one.
HOSTNAME="minecraft-papermc"
STORAGE="local-lvm"            # Storage where the LXC disk will live
TEMPLATE_STORAGE="local"       # Storage where Proxmox keeps templates (vztmpl)
DISK_SIZE_GB="20"
CORES="3"
RAM_MB="8192"
SWAP_MB="512"
BRIDGE="vmbr0"                 # Change if your bridge has a different name
NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=dhcp"
UNPRIVILEGED="1"

MC_PORT="25565"
JVM_XMS="2G"
JVM_XMX="6G"                   # Leaves ~2GB of headroom for the OS out of the LXC's 8GB
### ============================================================================

echo ">>> Updating LXC template catalog..."
pveam update >/dev/null

echo ">>> Looking up the latest Debian 12 template..."
TEMPLATE=$(pveam available --section system | grep "debian-12-standard" | awk '{print $2}' | sort -V | tail -n1)

if [ -z "$TEMPLATE" ]; then
  echo "ERROR: no debian-12-standard template found. Check 'pveam available'."
  exit 1
fi

echo "    Selected template: $TEMPLATE"

if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  echo ">>> Downloading template (not found locally)..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

if [ -z "$CTID" ]; then
  CTID=$(pvesh get /cluster/nextid)
  echo ">>> No CTID specified, using next free one: $CTID"
fi

if pct status "$CTID" &>/dev/null; then
  echo "ERROR: a container with CTID=$CTID already exists. Change the CTID variable in the script."
  exit 1
fi

echo ">>> Creating LXC $CTID ($HOSTNAME)..."
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM_MB" \
  --swap "$SWAP_MB" \
  --net0 "$NET_CONFIG" \
  --rootfs "${STORAGE}:${DISK_SIZE_GB}" \
  --unprivileged "$UNPRIVILEGED" \
  --features nesting=1 \
  --onboot 1

echo ">>> Starting LXC..."
pct start "$CTID"

echo ">>> Waiting for it to boot and get network (15s)..."
sleep 15

# Basic network check inside the container
for i in $(seq 1 10); do
  if pct exec "$CTID" -- getent hosts api.papermc.io &>/dev/null; then
    break
  fi
  echo "    Waiting for network inside the LXC... ($i/10)"
  sleep 3
done

### ==================== INNER SCRIPT (runs INSIDE the LXC) ====================
cat > /tmp/install-papermc-inner.sh <<'INNEREOF'
#!/usr/bin/env bash
set -euo pipefail

MC_USER="minecraft"
MC_DIR="/opt/minecraft"
JVM_XMS="__JVM_XMS__"
JVM_XMX="__JVM_XMX__"
MC_PORT="__MC_PORT__"

echo ">>> [LXC] Updating packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo ">>> [LXC] Installing dependencies (curl, jq)..."
apt-get install -y curl jq ca-certificates

echo ">>> [LXC] Installing Java 21 (ships in bookworm-backports, not in the standard repo)..."
echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/backports.list
apt-get update -y

if apt-get install -y -t bookworm-backports openjdk-21-jre-headless; then
  echo "    Java 21 installed from backports."
else
  echo "    WARNING: could not install Java 21, falling back to openjdk-17-jre-headless (may not be compatible with the most recent Paper builds)."
  apt-get install -y openjdk-17-jre-headless
fi

echo ">>> [LXC] Creating service user '$MC_USER'..."
if ! id "$MC_USER" &>/dev/null; then
  useradd -r -m -d "$MC_DIR" -s /usr/sbin/nologin "$MC_USER"
fi

mkdir -p "$MC_DIR"

echo ">>> [LXC] Querying the latest stable PaperMC version..."
API="https://api.papermc.io/v2/projects/paper"
LATEST_VERSION=$(curl -s "$API" | jq -r '.versions[-1]')
LATEST_BUILD=$(curl -s "${API}/versions/${LATEST_VERSION}" | jq -r '.builds[-1]')
JAR_NAME="paper-${LATEST_VERSION}-${LATEST_BUILD}.jar"

echo "    Minecraft version: $LATEST_VERSION  |  Paper build: $LATEST_BUILD"

echo ">>> [LXC] Downloading $JAR_NAME..."
curl -sL -o "${MC_DIR}/paper.jar" \
  "${API}/versions/${LATEST_VERSION}/builds/${LATEST_BUILD}/downloads/${JAR_NAME}"

echo ">>> [LXC] Accepting EULA..."
echo "eula=true" > "${MC_DIR}/eula.txt"

# Basic server.properties (feel free to edit later by hand)
if [ ! -f "${MC_DIR}/server.properties" ]; then
  cat > "${MC_DIR}/server.properties" <<PROPS
server-port=${MC_PORT}
enable-command-block=false
motd=Managed PaperMC server
online-mode=true
PROPS
fi

chown -R "${MC_USER}:${MC_USER}" "$MC_DIR"

echo ">>> [LXC] Creating systemd service..."
cat > /etc/systemd/system/minecraft.service <<SERVICE
[Unit]
Description=Minecraft PaperMC Server
After=network.target

[Service]
User=${MC_USER}
WorkingDirectory=${MC_DIR}
ExecStart=/usr/bin/java -Xms${JVM_XMS} -Xmx${JVM_XMX} -XX:+UseG1GC -jar paper.jar nogui
Restart=on-failure
RestartSec=10
StandardInput=null

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable minecraft
systemctl start minecraft

echo ">>> [LXC] Installation complete. Service status:"
sleep 3
systemctl status minecraft --no-pager || true
INNEREOF

# Substitute variables inside the inner script before pushing it
sed -i "s/__JVM_XMS__/${JVM_XMS}/" /tmp/install-papermc-inner.sh
sed -i "s/__JVM_XMX__/${JVM_XMX}/" /tmp/install-papermc-inner.sh
sed -i "s/__MC_PORT__/${MC_PORT}/" /tmp/install-papermc-inner.sh

echo ">>> Copying install script into the LXC..."
pct push "$CTID" /tmp/install-papermc-inner.sh /root/install-papermc-inner.sh

echo ">>> Running installation inside the LXC (this takes a few minutes)..."
pct exec "$CTID" -- bash /root/install-papermc-inner.sh

CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo ""
echo "================================================================"
echo " Done! PaperMC server running in LXC $CTID ($HOSTNAME)"
echo " Container IP: $CT_IP"
echo " Minecraft port: $MC_PORT"
echo ""
echo " Useful commands:"
echo "   pct exec $CTID -- systemctl status minecraft"
echo "   pct exec $CTID -- journalctl -u minecraft -f"
echo "   pct exec $CTID -- systemctl restart minecraft"
echo ""
echo " server.properties at: /opt/minecraft/server.properties (inside the LXC)"
echo "================================================================"
