#!/usr/bin/env bash
# onCreate.sh — Lifecycle-Hook, laeuft EINMAL beim Container-Create.
#
# Bei Prebuild-Workflows (z.B. Codespaces Prebuilds) laeuft dieses Skript
# bereits im Prebuild-Job und das Ergebnis wird ins Prebuild-Image gebrannt.
# Bei lokalen DevContainers laeuft es direkt vor postCreate.
#
# Voraussetzungen (von Feature):
#   - /opt/claude-code/cache/claude existiert (von install.sh)
#   - CLAUDE_CHANNEL gesetzt (stable|latest, default stable)
#   - CLAUDE_TARGET_USER optional gesetzt; sonst Auto-Detect
#
# Effekt:
#   - Fuehrt `claude install <channel>` als Target-User aus.
#   - Erzeugt ~/.local/bin/claude (Symlink) +
#     ~/.local/share/claude/versions/<v>/ (Binary).
#   - Konfiguriert Shell-Integration (PATH-Eintrag in ~/.bashrc o.ae.).
#
# WICHTIG: Dieser Schritt nutzt KEINEN Host-Bind-Mount und darf daher
# auch in Prebuild-Umgebungen laufen, in denen `/host_claude/...` fehlt.

set -euo pipefail

SCRIPT_TAG="claude-bootstrap"
. "$(dirname "$(readlink -f "$0")")/_lib.sh"

CC_CACHE_BIN="/opt/claude-code/cache/claude"
CC_CHANNEL="${CLAUDE_CHANNEL:-stable}"

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
