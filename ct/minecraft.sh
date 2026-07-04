#!/usr/bin/env bash

set -euo pipefail

# Configuración
MC_VERSION="1.21.1"
PAPER_BUILD="latest"
INSTALL_DIR="/opt/minecraft"
MC_USER="minecraft"
RAM_MIN="2G"
RAM_MAX="4G"
MC_PORT="25565"

echo "Actualizando sistema..."
apt update && apt upgrade -y

echo "Instalando dependencias base..."
apt install -y curl jq screen ufw wget gnupg ca-certificates lsb-release

install_java() {
    echo "Intentando instalar OpenJDK 21..."

    # Evita que set -e rompa el script si falla
    set +e
    apt install -y openjdk-21-jre-headless
    JAVA_STATUS=$?
    set -e

    if [ $JAVA_STATUS -eq 0 ]; then
        echo "OpenJDK 21 instalado correctamente."
        return
    fi

    echo "OpenJDK 21 no disponible. Instalando Temurin 21..."

    DISTRO_CODENAME=$(lsb_release -cs)

    wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | gpg --dearmor -o /etc/apt/trusted.gpg.d/adoptium.gpg

    echo "deb https://packages.adoptium.net/artifactory/deb ${DISTRO_CODENAME} main" \
        > /etc/apt/sources.list.d/adoptium.list

    apt update
    apt install -y temurin-21-jre

    echo "Temurin 21 instalado correctamente."
}

install_java

echo "Java instalado:"
java -version

if ! id "$MC_USER" &>/dev/null; then
    echo "Creando usuario minecraft..."
    useradd -r -m -U -d "$INSTALL_DIR" -s /bin/bash "$MC_USER"
fi

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Obteniendo última build de PaperMC..."

if [ "$PAPER_BUILD" = "latest" ]; then
    BUILD=$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}" \
        | jq '.builds[-1]')
else
    BUILD="$PAPER_BUILD"
fi

DOWNLOAD_URL="https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds/${BUILD}/downloads/paper-${MC_VERSION}-${BUILD}.jar"

echo "Descargando Paper build ${BUILD}..."
curl -fsSL -o paper.jar "$DOWNLOAD_URL"

if [ ! -f paper.jar ]; then
    echo "Error descargando PaperMC"
    exit 1
fi

echo "Aceptando EULA..."
echo "eula=true" > eula.txt

echo "Configurando server.properties..."
cat > server.properties <<EOF
server-port=${MC_PORT}
motd=PaperMC Server
enable-status=true
EOF

echo "Creando script de inicio..."
cat > start.sh <<EOF
#!/bin/bash
exec java -Xms${RAM_MIN} -Xmx${RAM_MAX} -XX:+UseG1GC -jar paper.jar nogui
EOF

chmod +x start.sh

echo "Asignando permisos..."
chown -R "$MC_USER:$MC_USER" "$INSTALL_DIR"

echo "Configurando firewall..."
ufw allow OpenSSH
ufw allow "${MC_PORT}/tcp"
ufw --force enable

echo "Creando servicio systemd..."
cat > /etc/systemd/system/minecraft.service <<EOF
[Unit]
Description=Minecraft Paper Server
After=network.target

[Service]
User=${MC_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/start.sh
Restart=always
RestartSec=10
SuccessExitStatus=0 1
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable minecraft
systemctl start minecraft

echo ""
echo "Instalación completada."
echo "Version: ${MC_VERSION}"
echo "Puerto abierto: ${MC_PORT}"
echo ""
echo "Comandos útiles:"
echo "systemctl status minecraft"
echo "journalctl -u minecraft -f"
echo "systemctl restart minecraft"
echo "systemctl stop minecraft"
