
#!/usr/bin/env bash

set -euo pipefail

NODE_EXPORTER_USER="node_exporter"
INSTALL_DIR="/usr/local/bin"
SERVICE_FILE="/etc/systemd/system/node_exporter.service"
TMP_DIR="/tmp/node_exporter_install"

log() {
  echo "[INFO] $1"
}

error() {
  echo "[ERROR] $1"
  exit 1
}

check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    error "Este script debe ejecutarse como root"
  fi
}

detect_arch() {
  ARCH=$(uname -m)

  case "$ARCH" in
    x86_64)
      EXPORTER_ARCH="amd64"
      ;;
    aarch64)
      EXPORTER_ARCH="arm64"
      ;;
    armv7l)
      EXPORTER_ARCH="armv7"
      ;;
    *)
      error "Arquitectura no soportada: $ARCH"
      ;;
  esac
}

get_latest_version() {
  log "Obteniendo última versión..."
  VERSION=$(curl -fsSL https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep '"tag_name":' | cut -d '"' -f4)

  if [[ -z "$VERSION" ]]; then
    error "No se pudo obtener la versión"
  fi
}

create_user() {
  if ! id "$NODE_EXPORTER_USER" &>/dev/null; then
    log "Creando usuario del sistema..."
    useradd --no-create-home --shell /bin/false "$NODE_EXPORTER_USER"
  fi
}

download_and_install() {
  mkdir -p "$TMP_DIR"
  cd "$TMP_DIR"

  FILE="node_exporter-${VERSION#v}.linux-${EXPORTER_ARCH}.tar.gz"
  URL="https://github.com/prometheus/node_exporter/releases/download/${VERSION}/${FILE}"

  log "Descargando $URL"
  curl -fsSLO "$URL"

  log "Extrayendo..."
  tar -xzf "$FILE"

  log "Instalando binario..."
  cp "node_exporter-${VERSION#v}.linux-${EXPORTER_ARCH}/node_exporter" "$INSTALL_DIR/"
  chown "$NODE_EXPORTER_USER:$NODE_EXPORTER_USER" "$INSTALL_DIR/node_exporter"
  chmod +x "$INSTALL_DIR/node_exporter"

  rm -rf "$TMP_DIR"
}

create_service() {
  log "Creando servicio systemd..."

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=${NODE_EXPORTER_USER}
Group=${NODE_EXPORTER_USER}
Type=simple
ExecStart=${INSTALL_DIR}/node_exporter \
  --collector.systemd \
  --collector.processes \
  --collector.tcpstat \
  --collector.interrupts \
  --collector.meminfo \
  --collector.netdev \
  --collector.filesystem \
  --collector.diskstats \
  --collector.uname \
  --collector.stat

Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

start_service() {
  log "Recargando systemd..."
  systemctl daemon-reload

  log "Habilitando servicio..."
  systemctl enable node_exporter

  log "Iniciando servicio..."
  systemctl restart node_exporter
}

open_firewall() {
  if command -v ufw &>/dev/null; then
    log "Abriendo puerto 9100 en UFW..."
    ufw allow 9100/tcp || true
  fi
}

verify() {
  log "Verificando métricas..."
  sleep 2

  if curl -fsSL http://localhost:9100/metrics >/dev/null; then
    log "Node Exporter funcionando correctamente en puerto 9100"
  else
    error "Node Exporter no responde"
  fi
}

main() {
  check_root
  detect_arch
  get_latest_version
  create_user
  download_and_install
  create_service
  start_service
  open_firewall
  verify

  log "Instalación completada"
}

main
