#!/usr/bin/env bash
# onCreate.sh — Lifecycle-Hook, laeuft EINMAL beim Container-Create.
#
# Bei Prebuild-Workflows (z.B. Codespaces Prebuilds) laeuft dieses Skript
# bereits im Prebuild-Job und das Ergebnis wird ins Prebuild-Image gebrannt.
# Bei lokalen DevContainers laeuft es direkt vor postCreate.
#
# Voraussetzungen (von Feature):
#   - /opt/claude-code/cache/claude existiert (von install.sh)
#   - CLAUDE_TARGET_USER optional gesetzt; sonst Auto-Detect
#
# Channel-Aufloesung (siehe resolve_release_channel in _lib.sh):
#   Feature-Option CLAUDE_CHANNEL -> Host-Settings -> Fallback "latest".
#   Im Prebuild-Pfad (kein Host-Mount) greift der Fallback; das ist OK,
#   weil postCreate/postStart spaeter ohnehin gegen den Host abgleichen
#   und ein Reinstall nicht noetig ist, solange autoUpdates aktiv sind.
#
# Effekt:
#   - Fuehrt `claude install <channel>` als Target-User aus.
#   - Erzeugt ~/.local/bin/claude (Symlink) +
#     ~/.local/share/claude/versions/<v>/ (Binary).
#   - Konfiguriert Shell-Integration (PATH-Eintrag in ~/.bashrc o.ae.).

set -euo pipefail

SCRIPT_TAG="claude-bootstrap"
. "$(dirname "$(readlink -f "$0")")/_lib.sh"

CC_CACHE_BIN="/opt/claude-code/cache/claude"
CC_CHANNEL="$(resolve_release_channel)"

resolve_target_paths

TARGET_LAUNCHER="${TARGET_HOME}/.local/bin/claude"

if [[ ! -x "$CC_CACHE_BIN" ]]; then
    fail "${CC_CACHE_BIN} not found or not executable — did Feature install.sh run?"
elif [[ -x "$TARGET_LAUNCHER" ]]; then
    log "claude already installed at ${TARGET_LAUNCHER} — skipping bootstrap"
else
    log "running 'claude install ${CC_CHANNEL}' as ${TARGET_USER}"
    run_as_target "$CC_CACHE_BIN" install "$CC_CHANNEL"
fi
