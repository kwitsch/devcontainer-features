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
# Basis: Account + onboarding-Flag. Ohne weitere Felder reicht das NICHT, um
# den First-Run-Wizard zu unterdruecken — Claude Code zeigt den Theme-Picker,
# wenn .theme fehlt, und ggf. Tip-Dialoge, wenn .tipsHistory leer ist.
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

# Wizard-state vom Host uebernehmen (Whitelist) — sonst kommt der Wizard
# trotz vorhandenem Login. Workspace-spezifische Felder (projects, mcpServers)
# bewusst nicht uebernehmen — die werden in postStart.sh per-Workspace gesetzt.
if [[ "${CLAUDE_FORWARD_HOST_ONBOARDING:-true}" == "true" ]]; then
    extracted_json="$(printf '%s' "$extracted_json" | jq \
        --slurpfile host "$HOST_JSON" \
        '. + ($host[0] | {
            theme,
            firstStartTime,
            tipsHistory,
            editorMode,
            autoUpdates,
            verbose,
            previewFeaturesOptInList,
            subscriptionNoticeCount,
            bypassPermissionsModeAccepted,
            hasAvailableSubscription
        } | with_entries(select(.value != null)))')"
fi

# Option-Override fuer theme (gewinnt gegen Host).
if [[ -n "${CLAUDE_THEME:-}" ]]; then
    extracted_json="$(printf '%s' "$extracted_json" | \
        jq --arg t "$CLAUDE_THEME" '.theme = $t')"
fi

# Fallback fuer firstStartTime — wenn weder Host noch Option gesetzt, das
# eine Feld, das Claude Code als Wizard-Trigger nutzt, mit "jetzt" fuellen.
extracted_json="$(printf '%s' "$extracted_json" | jq '
    if .firstStartTime == null then .firstStartTime = (now * 1000 | floor) else . end
')"

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

# --- Final step: install Claude Code IDE extension (anthropic.claude-code)
# Same mechanism the Claude Code binary itself uses internally when it
# detects an IDE without the extension:
#   <code-cli> --force --install-extension anthropic.claude-code
# We probe the well-known dev-container CLI locations (VS Code Server,
# VS Code Insiders Server, Cursor Server) under the target user's home,
# plus a final login-shell PATH fallback for non-standard setups.
# Soft-skip when nothing is found — Codespaces prebuilds, JetBrains
# hosts, and headless containers legitimately lack a VS Code CLI at
# this point.
if [[ "${CLAUDE_INSTALL_IDE_EXTENSION:-true}" == "true" ]]; then
    code_cli=""
    # (1) Well-known server install paths inside dev containers.
    #     Glob expands to the literal pattern when nothing matches —
    #     the `-x` guard filters that case out.
    for pattern in \
        "${TARGET_HOME}/.vscode-server/bin/"*"/bin/remote-cli/code" \
        "${TARGET_HOME}/.vscode-server-insiders/bin/"*"/bin/remote-cli/code-insiders" \
        "${TARGET_HOME}/.cursor-server/bin/"*"/bin/remote-cli/cursor"; do
        for candidate in $pattern; do
            if [[ -x "$candidate" ]]; then
                code_cli="$candidate"
                break 2
            fi
        done
    done
    # (2) PATH-based fallback (login shell to honour ~/.profile injection).
    if [[ -z "$code_cli" ]]; then
        for cand in code code-insiders cursor; do
            if run_as_target bash -lc "command -v ${cand} >/dev/null 2>&1"; then
                code_cli="$cand"
                break
            fi
        done
    fi

    if [[ -n "$code_cli" ]]; then
        log "installing IDE extension anthropic.claude-code via ${code_cli}"
        if ! run_as_target "$code_cli" --install-extension anthropic.claude-code --force; then
            warn "${code_cli} --install-extension anthropic.claude-code failed (non-fatal)"
        fi
    else
        log "no VS Code Server CLI found under ${TARGET_HOME} (.vscode-server / .vscode-server-insiders / .cursor-server) and none on PATH — IDE extension install skipped"
    fi
fi
