#!/usr/bin/env bash
# postCreate.sh — Lifecycle-Hook, laeuft EINMAL beim Container-Create
# (nach onCreate, nach Workspace-Mount, mit verfuegbarem Host-Bind-Mount).
#
# Aufgabe: Credentials + minimale .claude.json vom Host-Mount in den
# Target-User-Home schreiben. Der `claude install`-Schritt ist in
# onCreate.sh ausgelagert (Prebuild-cachebar).

set -euo pipefail

SCRIPT_TAG="claude-setup"
. "$(dirname "$(readlink -f "$0")")/_lib.sh"

HOST_DIR="${HOST_CLAUDE_MOUNT:-/host_claude}"
HOST_CREDS="${HOST_DIR}/.claude/.credentials.json"
HOST_JSON="${HOST_DIR}/.claude.json"

# --- Prerequisites ---------------------------------------------------------
command -v jq >/dev/null 2>&1 || fail "jq is required but not installed"

resolve_target_paths

# --- Validate host mount ---------------------------------------------------
[[ -r "$HOST_CREDS" ]] || { log "no host credentials at ${HOST_CREDS} — skipping"; exit 0; }
[[ -r "$HOST_JSON"  ]] || { log "no ${HOST_JSON} — skipping";                       exit 0; }

if ! jq -e '.claudeAiOauth.accessToken and .claudeAiOauth.refreshToken' \
        "$HOST_CREDS" >/dev/null 2>&1; then
    warn "credentials file malformed or tokens missing — skipping"
    exit 0
fi

# --- Build minimal .claude.json ------------------------------------------
extracted_json="$(jq '{
    userID:                 .userID,
    oauthAccount:           .oauthAccount,
    hasCompletedOnboarding: true
}' "$HOST_JSON")"

if ! printf '%s' "$extracted_json" | \
     jq -e '.userID and .oauthAccount' >/dev/null 2>&1; then
    warn "could not extract userID / oauthAccount from ${HOST_JSON} — skipping"
    exit 0
fi

# --- Install ---------------------------------------------------------------
# Harden TARGET_DIR einmalig — install_for_target laesst Parent-Dirs
# bewusst unangetastet.
mkdir -p "$TARGET_DIR"
chmod 700 "$TARGET_DIR"
if [[ "$(id -u)" -eq 0 ]]; then
    chown "${TARGET_USER}:${TARGET_USER}" "$TARGET_DIR"
fi

# install_for_target schreibt nach mktemp im Zielverzeichnis und macht
# einen atomaren rename. Damit folgen wir keinen Symlinks (das waere mit
# plain `cp` / shell-redirect bei root-execution gefaehrlich).
install_for_target "$HOST_CREDS" "$TARGET_CREDS" 600

tmp_json="$(mktemp)"
printf '%s\n' "$extracted_json" > "$tmp_json"
install_for_target "$tmp_json" "$TARGET_JSON" 600
rm -f "$tmp_json"

log "credentials and config installed for ${TARGET_USER}"

# --- Plugins + Marketplaces (Reihenfolge: erst marketplaces, dann plugins) ---
# Beide Optionen sind komma-getrennte Strings (Devcontainer-Feature-
# Konvention; native Arrays werden nicht unterstuetzt). Items werden
# zwischen den Kommas ge-trimmt; leere Items werden uebersprungen.
#
# Hinweis: Diese Sektion laeuft nur, wenn die credential-setup-Section
# nicht zuvor per `exit 0` ausgestiegen ist — entspricht der Anforderung
# "nach erfolgreichem login".
MARKETPLACES_CSV="${CLAUDE_MARKETPLACES:-}"
PLUGINS_CSV="${CLAUDE_PLUGINS:-}"

if [[ -n "$MARKETPLACES_CSV" ]] || [[ -n "$PLUGINS_CSV" ]]; then
    # Binary-Aufloesung: bevorzugt der vom `claude install` angelegte
    # Launcher; sonst der Bootstrap-Cache.
    CLAUDE_BIN="${TARGET_HOME}/.local/bin/claude"
    [[ -x "$CLAUDE_BIN" ]] || CLAUDE_BIN="/opt/claude-code/cache/claude"

    if [[ ! -x "$CLAUDE_BIN" ]]; then
        warn "no claude binary available — skipping plugin/marketplace setup"
    else
        # --- (1) Marketplaces zuerst ----------------------------------------
        if [[ -n "$MARKETPLACES_CSV" ]]; then
            IFS=',' read -ra MARKETPLACES <<< "$MARKETPLACES_CSV"
            for mp in "${MARKETPLACES[@]}"; do
                mp="$(trim_ws "$mp")"
                [[ -z "$mp" ]] && continue
                log "adding marketplace: ${mp}"
                if ! run_as_target "$CLAUDE_BIN" plugin marketplace add "$mp"; then
                    warn "marketplace add failed for: ${mp}"
                fi
            done
        fi

        # --- (2) Plugins danach ---------------------------------------------
        if [[ -n "$PLUGINS_CSV" ]]; then
            IFS=',' read -ra PLUGINS <<< "$PLUGINS_CSV"
            for plugin in "${PLUGINS[@]}"; do
                plugin="$(trim_ws "$plugin")"
                [[ -z "$plugin" ]] && continue
                log "installing plugin: ${plugin}"
                if ! run_as_target "$CLAUDE_BIN" plugin install "$plugin"; then
                    warn "plugin install failed for: ${plugin}"
                fi
            done
        fi
    fi
fi
