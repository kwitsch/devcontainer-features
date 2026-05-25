#!/usr/bin/env bash
# postStart.sh — laeuft bei jedem Container-Start.
#
# Aufgaben:
#   (1) Credentials refreshen, wenn der Host neuere Tokens hat
#       (Kriterium: claudeAiOauth.expiresAt strikt groesser).
#   (2) Bei Account-Wechsel auf dem Host (anderer userID) Account-Felder
#       in die existierende .claude.json mergen — Trust-/Remote-Control-
#       Felder bleiben dabei erhalten.
#   (3) Workspace-Trust + remoteControlAtStartup in .claude.json sichern.
#   (4) permissions.defaultMode = "auto" in settings.json sichern.

set -euo pipefail

SCRIPT_TAG="claude-refresh"
. "$(dirname "$(readlink -f "$0")")/_lib.sh"

HOST_DIR="${HOST_CLAUDE_MOUNT:-/host_claude}"
HOST_CREDS="${HOST_DIR}/.claude/.credentials.json"
HOST_JSON="${HOST_DIR}/.claude.json"

# --- Prerequisites --------------------------------------------------------
command -v jq >/dev/null 2>&1 || { warn "jq not found — skipping"; exit 0; }

resolve_target_paths

# Read a target-side JSON file, falling back to {} if missing or malformed.
# Prevents `set -euo pipefail` from killing the script on a corrupted
# .claude.json (manual edits, partial writes, etc.).
read_json_or_empty() {
    local f="$1"
    if [[ -f "$f" ]] && jq -e . "$f" >/dev/null 2>&1; then
        cat "$f"
    else
        printf '{}'
    fi
}

# Validate host credentials once; downstream steps gate on this flag rather
# than aborting the whole script — workspace trust and defaultMode below
# do not depend on credentials and should still run when none are mounted.
HOST_CREDS_OK=0
if [[ -r "$HOST_CREDS" ]] && \
   jq -e '.claudeAiOauth.accessToken and .claudeAiOauth.refreshToken' \
        "$HOST_CREDS" >/dev/null 2>&1; then
    HOST_CREDS_OK=1
else
    log "host credentials missing or malformed — skipping credential refresh"
fi

# --- (1) Credentials: kopieren wenn Host strikt neuer oder Container fehlt
if [[ "$HOST_CREDS_OK" == "1" ]]; then
    host_expires=$(jq -r '.claudeAiOauth.expiresAt // 0' "$HOST_CREDS")

    if [[ ! -f "$TARGET_CREDS" ]]; then
        log "no container credentials yet — installing from host"
        install_for_target "$HOST_CREDS" "$TARGET_CREDS" 600
    else
        container_expires=$(jq -r '.claudeAiOauth.expiresAt // 0' "$TARGET_CREDS" 2>/dev/null || echo 0)
        if [[ "$host_expires" -gt "$container_expires" ]]; then
            log "host credentials newer (${host_expires} > ${container_expires}) — refreshing"
            install_for_target "$HOST_CREDS" "$TARGET_CREDS" 600
        fi
    fi
fi

# --- (2) .claude.json: bei userID-Wechsel Account-Felder mergen -----------
#       (nicht ersetzen — sonst gingen Trust-/RemoteControl-Felder verloren)
if [[ "$HOST_CREDS_OK" == "1" && -r "$HOST_JSON" ]]; then
    host_uid=$(jq -r '.userID // empty' "$HOST_JSON")
    container_uid=$(jq -r '.userID // empty' "$TARGET_JSON" 2>/dev/null || true)

    if [[ -n "$host_uid" && "$host_uid" != "$container_uid" ]]; then
        log "userID changed on host — merging account fields into .claude.json"
        current="$(read_json_or_empty "$TARGET_JSON")"
        merged="$(jq -n \
            --argjson cur "$current" \
            --slurpfile host "$HOST_JSON" \
            '$cur * {
                userID:                 $host[0].userID,
                oauthAccount:           $host[0].oauthAccount,
                hasCompletedOnboarding: true
            }')"
        tmp_file="$(mktemp)"
        printf '%s\n' "$merged" > "$tmp_file"
        install_for_target "$tmp_file" "$TARGET_JSON" 600
        rm -f "$tmp_file"
    fi
fi

# --- (3) Workspace-Trust + Remote-Control: idempotent in .claude.json -----
#       Workspace-Trust:  immer (wenn Workspace-Pfad bekannt)
#       remoteControlAtStartup:  nur wenn Feature-Option `remoteControl=true`
WORKSPACE="${CLAUDE_WORKSPACE_PATH:-${PWD:-}}"
REMOTE_CONTROL="${CLAUDE_REMOTE_CONTROL:-true}"

[[ -z "$WORKSPACE" ]] && warn "no workspace path known (CLAUDE_WORKSPACE_PATH / PWD empty) — workspace-trust skipped"

current="$(read_json_or_empty "$TARGET_JSON")"

# Inkrementeller Aufbau der Merge-Pipeline
desired="$current"
if [[ "$REMOTE_CONTROL" == "true" ]]; then
    desired="$(printf '%s' "$desired" | jq '.remoteControlAtStartup = true')"
fi
if [[ -n "$WORKSPACE" ]]; then
    desired="$(printf '%s' "$desired" | jq --arg ws "$WORKSPACE" '
        .projects = ((.projects // {}) | .[$ws] = ((.[$ws] // {})
            | .hasTrustDialogAccepted        = true
            | .hasTrustDialogHooksAccepted   = true
            | .hasCompletedProjectOnboarding = true
        ))
    ')"
fi

if [[ "$(printf '%s' "$current"  | jq -S .)" != \
      "$(printf '%s' "$desired"  | jq -S .)" ]]; then
    log "patching .claude.json (remoteControl=${REMOTE_CONTROL}, workspace=${WORKSPACE:-<none>})"
    tmp_file="$(mktemp)"
    printf '%s\n' "$desired" > "$tmp_file"
    install_for_target "$tmp_file" "$TARGET_JSON" 600
    rm -f "$tmp_file"
fi

# --- (4) permissions.defaultMode in ~/.claude/settings.json ---------------
#       Nur setzen wenn CLAUDE_DEFAULT_MODE nicht leer ist.
DEFAULT_MODE="${CLAUDE_DEFAULT_MODE:-}"

if [[ -z "$DEFAULT_MODE" ]]; then
    log "defaultMode option empty — settings.json not touched"
else
    cur_settings="$(read_json_or_empty "$TARGET_SETTINGS")"

    new_settings="$(printf '%s' "$cur_settings" | jq --arg mode "$DEFAULT_MODE" '
        .permissions = ((.permissions // {}) | .defaultMode = $mode)
    ')"

    if [[ "$(printf '%s' "$cur_settings" | jq -S .)" != \
          "$(printf '%s' "$new_settings" | jq -S .)" ]]; then
        log "setting permissions.defaultMode = \"${DEFAULT_MODE}\" in ${TARGET_SETTINGS}"
        tmp_file="$(mktemp)"
        printf '%s\n' "$new_settings" > "$tmp_file"
        install_for_target "$tmp_file" "$TARGET_SETTINGS" 600
        rm -f "$tmp_file"
    fi
fi

# --- (5) Optional: claude remote-control --spawn worktree als Daemon -----
#       (Feature-Option remoteControlServer = true)
START_RC_SERVER="${CLAUDE_REMOTE_CONTROL_SERVER:-false}"

if [[ "$START_RC_SERVER" == "true" ]]; then
    if [[ -z "$WORKSPACE" ]]; then
        warn "remoteControlServer requested but no workspace path known — skipping"
    elif [[ ! -e "$WORKSPACE/.git" ]]; then
        warn "remoteControlServer requested but ${WORKSPACE} is not a git repo (--spawn worktree requires git) — skipping"
    else
        PID_FILE="${TARGET_DIR}/remote-control.pid"
        LOG_FILE="${TARGET_DIR}/remote-control.log"

        # Idempotenz: schon laufenden Daemon erkennen
        if [[ -r "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
            log "claude remote-control already running (pid $(cat "$PID_FILE")) — skipping spawn"
        else
            # Bevorzugt den vom `claude install` angelegten Launcher, sonst Cache-Binary
            CLAUDE_BIN="${TARGET_HOME}/.local/bin/claude"
            [[ -x "$CLAUDE_BIN" ]] || CLAUDE_BIN="/opt/claude-code/cache/claude"

            mkdir -p "$TARGET_DIR" 2>/dev/null || true

            log "spawning 'claude remote-control --spawn worktree' as ${TARGET_USER} (log: ${LOG_FILE})"
            if pid=$(run_as_target_background "$LOG_FILE" \
                        "$CLAUDE_BIN" remote-control --spawn worktree); then
                echo "$pid" > "$PID_FILE"
                if [[ "$(id -u)" -eq 0 ]]; then
                    chown "${TARGET_USER}:${TARGET_USER}" \
                        "$PID_FILE" "$LOG_FILE" 2>/dev/null || true
                fi
                log "remote-control daemon spawned (pid=${pid})"
            else
                warn "could not spawn as ${TARGET_USER} (need root, target-user, or passwordless sudo) — daemon not started"
            fi
        fi
    fi
fi
