#!/bin/bash
#
# provision.sh
# Script de aprovisionamiento interactivo para el servidor.
# Ejecutar manualmente tras la instalación desatendida de Ubuntu.
#
set -euo pipefail

# --- Trap de seguridad: limpia las variables de contraseña al salir ---
cleanup() {
    unset PANEL_PASS DISCO
}
trap cleanup EXIT

echo "=============================================="
echo "  Aprovisionamiento del Servidor (Interactivo)"
echo "=============================================="
echo

# --- 1. Recoger datos del usuario (sin eco para contraseñas) ---
read -r -s -p "Contraseña para el panel de 1Panel (usuario admin): " PANEL_PASS; echo
if [[ -z "$PANEL_PASS" ]]; then
    echo "❌ La contraseña de 1Panel no puede estar vacía."
    exit 1
fi

# Preguntar por el disco de 4TB (con confirmación explícita)
echo
echo "⚠️  ATENCIÓN: El siguiente paso formateará un disco completo."
read -r -p "Introduce el dispositivo del disco de 4TB para Seafile (ej. /dev/sdb): " DISCO
if [[ -z "$DISCO" ]]; then
    echo "❌ No se ha indicado ningún disco. Abortando por seguridad."
    exit 1
fi
read -r -p "¿Confirmas que '$DISCO' es el disco de 4TB y que se puede borrar? [s/N]: " CONFIRM
if [[ "${CONFIRM,,}" != "s" && "${CONFIRM,,}" != "si" && "${CONFIRM,,}" != "sí" ]]; then
    echo "Abortado por el usuario."
    exit 1
fi

# --- 2. Actualización e instalación de dependencias base ---
echo
echo ">>> Actualizando el sistema e instalando dependencias base..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git firewalld openssl

# --- 3. Configurar firewalld (política restrictiva) ---
echo
echo ">>> Configurando firewalld (política 'drop' por defecto)..."
sudo firewall-cmd --set-default-zone=drop
sudo firewall-cmd --permanent --add-service=ssh
# Permitir el puerto de 1Panel solo desde la red local (ajusta la subred si es necesario)
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="192.168.1.0/24" port port="8090" protocol="tcp" accept'
sudo firewall-cmd --reload
echo "✅ Firewalld configurado. SSH permitido. Puerto 8090 (1Panel) abierto solo para LAN."

# --- 4. Instalar 1Panel (modo no interactivo para automatizar) ---
echo
echo ">>> Instalando 1Panel (modo no interactivo)..."
# Usamos las variables de entorno para evitar las preguntas del instalador.
# Se instala Docker automáticamente (PANEL_INSTALL_DOCKER=y).
PANEL_NON_INTERACTIVE=true \
PANEL_LANG=en \
PANEL_PORT=8090 \
PANEL_ENTRANCE=panel \
PANEL_USERNAME=admin \
PANEL_PASSWORD="$PANEL_PASS" \
PANEL_INSTALL_DOCKER=y \
PANEL_DOCKER_MODE=auto \
bash -c "$(curl -sSL https://resource.fit2cloud.com/1panel/package/v2/quick_start.sh)"
echo "✅ 1Panel instalado en el puerto 8090 (entrada: 'panel')."

# --- 5. Instalar Cockpit (consola secundaria) ---
echo
echo ">>> Instalando Cockpit..."
sudo apt install -y cockpit
sudo systemctl enable --now cockpit.socket
echo "✅ Cockpit instalado y escuchando en el puerto 9090."

# --- 6. Desplegar NetBird (cliente) usando Docker ---
echo
echo ">>> Preparando NetBird..."
# Pedir la setup key al usuario (también de forma segura)
read -r -s -p "Introduce tu Setup Key de NetBird: " NB_KEY; echo
if [[ -z "$NB_KEY" ]]; then
    echo "⚠️  No se ha introducido Setup Key. NetBird no se iniciará."
else
    # Verificar que Docker está corriendo (1Panel lo instaló)
    if command -v docker &> /dev/null && sudo docker info &> /dev/null; then
        sudo docker run --network host --privileged --rm -d \
          --name netbird \
          -e NB_SETUP_KEY="$NB_KEY" \
          -v netbird-client:/var/lib/netbird \
          netbirdio/netbird:latest
        echo "✅ NetBird iniciado."
    else
        echo "❌ Docker no está disponible. NetBird no se pudo iniciar."
    fi
    unset NB_KEY
fi

# --- 7. Preparar el disco de 4 TB para Seafile ---
echo
echo ">>> Preparando el disco $DISCO para Seafile..."
# ADVERTENCIA: Esto borra el disco.
sudo parted "$DISCO" mklabel gpt
sudo parted -a opt "$DISCO" mkpart primary ext4 0% 100%
# Formatear la primera partición
sudo mkfs.ext4 "${DISCO}1"
# Crear punto de montaje y montar
sudo mkdir -p /mnt/datos-seafile
# Añadir a fstab para montaje persistente
UUID=$(sudo blkid -s UUID -o value "${DISCO}1")
if [[ -n "$UUID" ]]; then
    echo "UUID=$UUID /mnt/datos-seafile ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
    sudo mount -a
    echo "✅ Disco montado en /mnt/datos-seafile."
else
    echo "❌ No se pudo obtener el UUID del disco. Revisa manualmente."
fi
# Crear subcarpeta para los datos de Seafile y ajustar permisos (UID típico de Seafile en contenedor)
sudo mkdir -p /mnt/datos-seafile/seafile-data
sudo chown -R 2016:2016 /mnt/datos-seafile/seafile-data
echo "✅ Carpeta de datos de Seafile preparada en /mnt/datos-seafile/seafile-data."

# --- 8. Mensaje final ---
echo
echo "=============================================="
echo "  Aprovisionamiento base completado."
echo "=============================================="
echo "Ahora debes:"
echo "1. Acceder a 1Panel (https://IP:8090) y desplegar desde su tienda:"
echo "   - Nginx Proxy Manager"
echo "   - Pi-hole"
echo "   - Unbound"
echo "   - Seafile (mapeando el volumen /shared a /mnt/datos-seafile/seafile-data)"
echo "2. Desplegar Collabora manualmente (contenedor 'collabora/code:latest', puerto 9980)."
echo "3. Configurar NPM: Proxy Hosts para Seafile y Collabora (con SSL y Websockets)."
echo "4. Editar seahub_settings.py en el contenedor de Seafile para enlazar con Collabora."
echo
