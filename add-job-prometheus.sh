#!/usr/bin/env bash

set -euo pipefail

PROM_CONFIG="/etc/prometheus/prometheus.yml"

log() {
  echo "[INFO] $1"
}

error() {
  echo "[ERROR] $1"
  exit 1
}

check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    error "Ejecuta como root"
  fi
}

check_args() {
  if [[ $# -lt 2 ]]; then
    echo "Uso: $0 <job_name> <target>"
    echo "Ejemplo: $0 it-tools 192.168.1.45:9100"
    exit 1
  fi
}

backup_config() {
  BACKUP="${PROM_CONFIG}.bak.$(date +%s)"
  cp "$PROM_CONFIG" "$BACKUP"
  log "Backup creado: $BACKUP"
}

job_exists() {
  local JOB_NAME="$1"

  if grep -q "job_name: '$JOB_NAME'" "$PROM_CONFIG"; then
    return 0
  fi

  return 1
}

append_job() {
  local JOB_NAME="$1"
  local TARGET="$2"

  cat <<EOF >> "$PROM_CONFIG"

  - job_name: '$JOB_NAME'
    static_configs:
      - targets:
          - '$TARGET'
EOF

  log "Job añadido: $JOB_NAME -> $TARGET"
}

validate_config() {
  if command -v promtool &>/dev/null; then
    log "Validando configuración..."

    if promtool check config "$PROM_CONFIG"; then
      log "Configuración válida"
    else
      error "Configuración inválida. Revirtiendo backup."
    fi
  else
    log "promtool no encontrado. Saltando validación."
  fi
}

reload_prometheus() {
  log "Recargando Prometheus..."
  systemctl reload prometheus || systemctl restart prometheus
}

main() {
  check_root
  check_args "$@"

  JOB_NAME="$1"
  TARGET="$2"

  if [[ ! -f "$PROM_CONFIG" ]]; then
    error "No existe $PROM_CONFIG"
  fi

  if job_exists "$JOB_NAME"; then
    error "El job '$JOB_NAME' ya existe"
  fi

  backup_config
  append_job "$JOB_NAME" "$TARGET"
  validate_config
  reload_prometheus

  log "Proceso completado"
}

main "$@"
