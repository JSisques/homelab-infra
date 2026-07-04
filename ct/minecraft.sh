#!/usr/bin/env bash

set -e

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

echo "Instalando dependencias..."
apt install -y curl jq screen openjdk-21-jre-headless ufw

if ! id "$MC_USER" &>/dev/null; then
    echo "Creando usuario minecraft..."
    useradd -r -m -U -d $INSTALL_DIR -s /bin/bash $MC_USER
fi

mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

echo "Obteniendo última build de PaperMC..."

if [ "$PAPER_BUILD" = "latest" ]; then
    BUILD=$(curl -s https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION} \
        | jq '.builds[-1]')
else
    BUILD=$PAPER_BUILD
fi

DOWNLOAD_URL="https://api.papermc.io/v2/projects/paper/versions/${MC_VERSION}/builds/${BUILD}/downloads/paper-${MC_VERSION}-${BUILD}.jar"

echo "Descargando Paper build ${BUILD}..."
curl -o paper.jar $DOWNLOAD_URL

echo "Aceptando EULA..."
echo "eula=true" > eula.txt

echo "Creando script de inicio..."
cat > start.sh <<EOF
#!/bin/bash
java -Xms${RAM_MIN} -Xmx${RAM_MAX} -XX:+UseG1GC -jar paper.jar nogui
EOF

chmod +x start.sh

echo "Asignando permisos..."
chown -R $MC_USER:$MC_USER $INSTALL_DIR

echo "Configurando firewall..."
ufw allow ${MC_PORT}/tcp
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable minecraft
systemctl start minecraft

echo ""
echo "Instalación completada."
echo "Puerto abierto: ${MC_PORT}"
echo "Comandos útiles:"
echo "systemctl status minecraft"
echo "journalctl -u minecraft -f"
echo "systemctl restart minecraft"
