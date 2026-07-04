#!/usr/bin/env bash
#
# create-papermc-lxc.sh
# ----------------------------------------------------------------------------
# Ejecutar en la SHELL DEL NODO PROXMOX (no dentro de un LXC).
# Crea un LXC Debian 12 y le instala Java + PaperMC (última versión estable)
# con un servicio systemd, listo para arrancar.
#
# Uso:
#   chmod +x create-papermc-lxc.sh
#   ./create-papermc-lxc.sh
# ----------------------------------------------------------------------------

set -euo pipefail

### ==================== CONFIGURACIÓN (edítala si quieres) ====================
CTID="200"                     # ID del LXC. Cambia si ya usas ese ID (pct list para ver los que hay)
HOSTNAME="minecraft-papermc"
STORAGE="local-lvm"            # Storage donde vivirá el disco del LXC
TEMPLATE_STORAGE="local"       # Storage donde Proxmox guarda las plantillas (vztmpl)
DISK_SIZE_GB="20"
CORES="3"
RAM_MB="8192"
SWAP_MB="512"
BRIDGE="vmbr0"                 # Cambia si tu bridge se llama distinto
NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=dhcp"
UNPRIVILEGED="1"

MC_PORT="25565"
JVM_XMS="2G"
JVM_XMX="6G"                   # Dejamos ~2GB de margen para el SO sobre los 8GB del LXC
### ==============================================================================

echo ">>> Actualizando catálogo de plantillas LXC..."
pveam update >/dev/null

echo ">>> Buscando la última plantilla de Debian 12..."
TEMPLATE=$(pveam available --section system | grep "debian-12-standard" | awk '{print $2}' | sort -V | tail -n1)

if [ -z "$TEMPLATE" ]; then
  echo "ERROR: no se encontró ninguna plantilla debian-12-standard. Revisa 'pveam available'."
  exit 1
fi

echo "    Plantilla seleccionada: $TEMPLATE"

if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  echo ">>> Descargando plantilla (no estaba en local)..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

if pct status "$CTID" &>/dev/null; then
  echo "ERROR: ya existe un contenedor con CTID=$CTID. Cambia la variable CTID en el script."
  exit 1
fi

echo ">>> Creando LXC $CTID ($HOSTNAME)..."
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

echo ">>> Arrancando LXC..."
pct start "$CTID"

echo ">>> Esperando a que arranque y tenga red (15s)..."
sleep 15

# Comprobación básica de red dentro del contenedor
for i in $(seq 1 10); do
  if pct exec "$CTID" -- getent hosts api.papermc.io &>/dev/null; then
    break
  fi
  echo "    Esperando red dentro del LXC... ($i/10)"
  sleep 3
done

### ==================== SCRIPT INTERNO (se ejecuta DENTRO del LXC) ====================
cat > /tmp/install-papermc-inner.sh <<'INNEREOF'
#!/usr/bin/env bash
set -euo pipefail

MC_USER="minecraft"
MC_DIR="/opt/minecraft"
JVM_XMS="__JVM_XMS__"
JVM_XMX="__JVM_XMX__"
MC_PORT="__MC_PORT__"

echo ">>> [LXC] Actualizando paquetes..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo ">>> [LXC] Instalando dependencias (curl, jq)..."
apt-get install -y curl jq ca-certificates

echo ">>> [LXC] Instalando Java 21 (viene en bookworm-backports, no en el repo estándar)..."
echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/backports.list
apt-get update -y

if apt-get install -y -t bookworm-backports openjdk-21-jre-headless; then
  echo "    Java 21 instalado desde backports."
else
  echo "    AVISO: no se pudo instalar Java 21, usando openjdk-17-jre-headless (puede no ser compatible con builds de Paper muy recientes)."
  apt-get install -y openjdk-17-jre-headless
fi

echo ">>> [LXC] Creando usuario de servicio '$MC_USER'..."
if ! id "$MC_USER" &>/dev/null; then
  useradd -r -m -d "$MC_DIR" -s /usr/sbin/nologin "$MC_USER"
fi

mkdir -p "$MC_DIR"

echo ">>> [LXC] Consultando última versión estable de PaperMC..."
API="https://api.papermc.io/v2/projects/paper"
LATEST_VERSION=$(curl -s "$API" | jq -r '.versions[-1]')
LATEST_BUILD=$(curl -s "${API}/versions/${LATEST_VERSION}" | jq -r '.builds[-1]')
JAR_NAME="paper-${LATEST_VERSION}-${LATEST_BUILD}.jar"

echo "    Versión Minecraft: $LATEST_VERSION  |  Build Paper: $LATEST_BUILD"

echo ">>> [LXC] Descargando $JAR_NAME..."
curl -sL -o "${MC_DIR}/paper.jar" \
  "${API}/versions/${LATEST_VERSION}/builds/${LATEST_BUILD}/downloads/${JAR_NAME}"

echo ">>> [LXC] Aceptando EULA..."
echo "eula=true" > "${MC_DIR}/eula.txt"

# server.properties básico (se puede editar luego a mano)
if [ ! -f "${MC_DIR}/server.properties" ]; then
  cat > "${MC_DIR}/server.properties" <<PROPS
server-port=${MC_PORT}
enable-command-block=false
motd=Servidor PaperMC gestionado
online-mode=true
PROPS
fi

chown -R "${MC_USER}:${MC_USER}" "$MC_DIR"

echo ">>> [LXC] Creando servicio systemd..."
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

echo ">>> [LXC] Instalación completada. Estado del servicio:"
sleep 3
systemctl status minecraft --no-pager || true
INNEREOF

# Sustituir variables dentro del script interno antes de enviarlo
sed -i "s/__JVM_XMS__/${JVM_XMS}/" /tmp/install-papermc-inner.sh
sed -i "s/__JVM_XMX__/${JVM_XMX}/" /tmp/install-papermc-inner.sh
sed -i "s/__MC_PORT__/${MC_PORT}/" /tmp/install-papermc-inner.sh

echo ">>> Copiando script de instalación al LXC..."
pct push "$CTID" /tmp/install-papermc-inner.sh /root/install-papermc-inner.sh

echo ">>> Ejecutando instalación dentro del LXC (esto tarda unos minutos)..."
pct exec "$CTID" -- bash /root/install-papermc-inner.sh

CT_IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo ""
echo "================================================================"
echo " ¡Listo! Servidor PaperMC funcionando en el LXC $CTID ($HOSTNAME)"
echo " IP del contenedor: $CT_IP"
echo " Puerto Minecraft:  $MC_PORT"
echo ""
echo " Comandos útiles:"
echo "   pct exec $CTID -- systemctl status minecraft"
echo "   pct exec $CTID -- journalctl -u minecraft -f"
echo "   pct exec $CTID -- systemctl restart minecraft"
echo ""
echo " server.properties en: /opt/minecraft/server.properties (dentro del LXC)"
echo "================================================================"
