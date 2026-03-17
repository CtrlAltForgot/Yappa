#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP_DIR="$SCRIPT_DIR"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
APP_ID="chat.yappa.client"
DESKTOP_FILE="$DESKTOP_DIR/${APP_ID}.desktop"
ICON_FILE="$APP_DIR/assets/yappa_logo.png"
EXEC_FILE="$APP_DIR/Yappa"
LAUNCHER_FILE="$APP_DIR/run-yappa.sh"

if [[ ! -x "$EXEC_FILE" ]]; then
  echo "Yappa launcher error: bundled binary not found at $EXEC_FILE" >&2
  exit 1
fi

mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Yappa
Comment=Open-source self-hosted chat client
Exec=$LAUNCHER_FILE --direct-exec %U
Icon=$ICON_FILE
Terminal=false
Categories=Network;Chat;
StartupNotify=true
StartupWMClass=Yappa
X-GNOME-UsesNotifications=true
DBusActivatable=false
EOF

chmod 644 "$DESKTOP_FILE"
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

if [[ -z "${XDG_CURRENT_DESKTOP:-}" ]]; then
  if [[ -n "${KDE_FULL_SESSION:-}" ]] || [[ "${DESKTOP_SESSION:-}" =~ plasma|kde ]]; then
    export XDG_CURRENT_DESKTOP=KDE
  elif [[ "${XDG_SESSION_DESKTOP:-}" =~ gnome|ubuntu ]] || [[ "${DESKTOP_SESSION:-}" =~ gnome|ubuntu ]]; then
    export XDG_CURRENT_DESKTOP=GNOME
  fi
fi

IMPORT_VARS=(
  DISPLAY
  WAYLAND_DISPLAY
  XDG_CURRENT_DESKTOP
  XDG_SESSION_TYPE
  XAUTHORITY
  DBUS_SESSION_BUS_ADDRESS
  PATH
  XDG_DATA_DIRS
)

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user import-environment "${IMPORT_VARS[@]}" >/dev/null 2>&1 || true
fi

if command -v dbus-update-activation-environment >/dev/null 2>&1; then
  dbus-update-activation-environment --systemd "${IMPORT_VARS[@]}" >/dev/null 2>&1 || \
    dbus-update-activation-environment "${IMPORT_VARS[@]}" >/dev/null 2>&1 || true
fi

export GTK_USE_PORTAL=1

if command -v gdbus >/dev/null 2>&1; then
  if ! gdbus introspect \
      --session \
      --dest org.freedesktop.portal.Desktop \
      --object-path /org/freedesktop/portal/desktop \
      >/tmp/yappa-portal-check.txt 2>/dev/null || \
     ! grep -q "org.freedesktop.portal.ScreenCast" /tmp/yappa-portal-check.txt; then
    echo "Yappa warning: ScreenCast portal is unavailable. Screen sharing on Linux needs xdg-desktop-portal, a matching portal backend for the current desktop session, and PipeWire." >&2
  fi
  rm -f /tmp/yappa-portal-check.txt
fi

if [[ "${1:-}" == "--direct-exec" ]]; then
  shift
fi

exec "$EXEC_FILE" "$@"
