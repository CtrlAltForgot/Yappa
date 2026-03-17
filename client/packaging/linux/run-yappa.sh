#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP_DIR="$SCRIPT_DIR"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$DESKTOP_DIR/chat.yappa.client.desktop"
ICON_FILE="$APP_DIR/assets/yappa_logo.png"
EXEC_FILE="$APP_DIR/Yappa"

mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Yappa
Comment=Open-source self-hosted chat client
Exec="$EXEC_FILE"
Icon="$ICON_FILE"
Terminal=false
Categories=Network;Chat;
StartupNotify=true
StartupWMClass=Yappa
X-GNOME-UsesNotifications=true
EOF

chmod 644 "$DESKTOP_FILE"

export GTK_USE_PORTAL=1
exec "$EXEC_FILE" "$@"
