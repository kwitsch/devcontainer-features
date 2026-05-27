#!/usr/bin/env bash
# postStart.sh — laeuft bei jedem Container-Start.
#
# Aufgaben:
#   (1) Credentials refreshen, wenn der Host neuere Tokens hat
#       (Kriterium: claudeAiOauth.expiresAt strikt groesser).
#   (2) Bei Account-Wechsel auf dem Host (anderer userID) Account-Felder
#       in die existierende .claude.json mergen — Trust-/Dialog-Felder
#       bleiben dabei erhalten.
#   (3) Workspace-Trust (per-Projekt) + remoteDialogSeen in .claude.json.
#   (4) settings.json: permissions.defaultMode, remoteControlAtStartup
#       und die zugehoerigen skip*-Opt-in-Flags. Wichtig: remoteControl
#       UND auto-mode-Opt-out leben in settings.json, NICHT in .claude.json
#       (Stand Claude Code >= 2.1.83).

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
    # `tonumber? // 0`: bei null/missing/string-Werten faellt auf 0 zurueck,
    # statt mit ParseError unter set -e die ganze Hook abzubrechen.
    host_expires=$(jq -r '(.claudeAiOauth.expiresAt | tonumber? // 0)' "$HOST_CREDS")

    if [[ ! -f "$TARGET_CREDS" ]]; then
        log "no container credentials yet — installing from host"
        install_for_target "$HOST_CREDS" "$TARGET_CREDS" 600
    else
        container_expires=$(jq -r '(.claudeAiOauth.expiresAt | tonumber? // 0)' "$TARGET_CREDS" 2>/dev/null || echo 0)
        if [[ "$host_expires" -gt "$container_expires" ]]; then
            log "host credentials newer (${host_expires} > ${container_expires}) — refreshing"
            install_for_target "$HOST_CREDS" "$TARGET_CREDS" 600
        fi
    fi
fi

# --- (2) .claude.json: bei userID-Wechsel Account-Felder mergen -----------
#       (nicht ersetzen — sonst gingen Trust-/RemoteControl-Felder verloren)
FORWARD_HOST_ONBOARDING="${CLAUDE_FORWARD_HOST_ONBOARDING:-true}"
THEME_OPT="${CLAUDE_THEME:-}"

if [[ "$HOST_CREDS_OK" == "1" && -r "$HOST_JSON" ]] && \
   jq -e . "$HOST_JSON" >/dev/null 2>&1; then
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

# --- (2b) Wizard-state idempotent nachziehen ------------------------------
#       Schliesst zwei Luecken:
#         - aeltere Feature-Versionen haben kein theme/firstStartTime
#           geschrieben (re-run auf persistent volume).
#         - Host wurde nach Container-Create neu eingeloggt (postCreate
#           war bereits durch, hat aber nur Account-Felder uebernommen).
#       Bestehende Werte werden NICHT ueberschrieben (ausser Theme-Option).
current="$(read_json_or_empty "$TARGET_JSON")"
desired_wizard="$current"

if [[ "$FORWARD_HOST_ONBOARDING" == "true" && -r "$HOST_JSON" ]] && \
   jq -e . "$HOST_JSON" >/dev/null 2>&1; then
    desired_wizard="$(printf '%s' "$desired_wizard" | jq \
        --slurpfile host "$HOST_JSON" \
        '($host[0] | {
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
        } | with_entries(select(.value != null))) as $h
         | $h * .')"
fi

# Theme-Option wirkt als Override (gewinnt sowohl ueber Host als auch
# ueber bestehenden Wert) — sonst bliebe ein vom Host uebernommener Wert
# trotz explizitem Option-Wert.
if [[ -n "$THEME_OPT" ]]; then
    desired_wizard="$(printf '%s' "$desired_wizard" | \
        jq --arg t "$THEME_OPT" '.theme = $t')"
fi

# Sicherheitsnetz: wenn theme nach all dem immer noch leer ist (z.B. weder
# Host noch Option setzen es), default auf "dark" — dann kommt der Picker
# garantiert nicht.
desired_wizard="$(printf '%s' "$desired_wizard" | jq '
    if (.theme // "") == "" then .theme = "dark" else . end
  | if .hasCompletedOnboarding != true then .hasCompletedOnboarding = true else . end
  | if .firstStartTime == null then .firstStartTime = (now * 1000 | floor) else . end
')"

if [[ "$(printf '%s' "$current"        | jq -S .)" != \
      "$(printf '%s' "$desired_wizard" | jq -S .)" ]]; then
    log "patching .claude.json wizard fields"
    tmp_file="$(mktemp)"
    printf '%s\n' "$desired_wizard" > "$tmp_file"
    install_for_target "$tmp_file" "$TARGET_JSON" 600
    rm -f "$tmp_file"
fi

# --- (3) Workspace-Trust + remoteDialogSeen in .claude.json ---------------
#       Workspace-Trust (per Projekt):  fuer den aufgeloesten Workspace,
#                                       seinen realpath UND /workspaces
#                                       inkl. allen unmittelbaren Subdirs.
#                                       Claude prueft Trust per exact-path
#                                       gegen .projects[<cwd>] — abweichende
#                                       Pfade (Symlink, anderes Repo im
#                                       selben /workspaces) wuerden sonst
#                                       erneut den Dialog zeigen. Felder die
#                                       das Binary tatsaechlich liest:
#                                       hasTrustDialogAccepted +
#                                       hasCompletedProjectOnboarding.
#       remoteDialogSeen (top-level):   nur wenn remoteControl=true
#                                       (sonst erscheint der einmalige
#                                       Remote-Control-Hinweisdialog).
WORKSPACE="$(resolve_workspace_folder)"
REMOTE_CONTROL="${CLAUDE_REMOTE_CONTROL:-true}"

# Liste der zu trustenden Pfade aufbauen (Dedup ueber assoziatives Array).
declare -A trust_set=()
add_trust_path() {
    local p="$1"
    [[ -z "$p" || "$p" == "/" ]] && return
    [[ "$p" == /* ]] || return
    [[ -d "$p" ]] || return
    trust_set["$p"]=1
}

add_trust_path "$WORKSPACE"
if [[ -n "$WORKSPACE" ]] && command -v realpath >/dev/null 2>&1; then
    real_ws="$(realpath -m "$WORKSPACE" 2>/dev/null || true)"
    add_trust_path "$real_ws"
fi
if [[ -d /workspaces ]]; then
    add_trust_path "/workspaces"
    for d in /workspaces/*/; do
        [[ -d "$d" ]] && add_trust_path "${d%/}"
    done
fi

current="$(read_json_or_empty "$TARGET_JSON")"
desired="$current"

if [[ "$REMOTE_CONTROL" == "true" ]]; then
    desired="$(printf '%s' "$desired" | jq '.remoteDialogSeen = true')"
fi
# Migrationspfad: aeltere Feature-Versionen haben remoteControlAtStartup
# faelschlich hierher geschrieben — entfernen, sonst bleibt der tote Key
# in der Datei und stiftet Verwirrung. Der echte Wert sitzt in settings.json.
desired="$(printf '%s' "$desired" | jq 'del(.remoteControlAtStartup)')"

if (( ${#trust_set[@]} == 0 )); then
    warn "no trustable paths found (PWD invalid, /workspaces missing) — workspace-trust skipped"
else
    for p in "${!trust_set[@]}"; do
        desired="$(printf '%s' "$desired" | jq --arg ws "$p" '
            .projects = ((.projects // {}) | .[$ws] = ((.[$ws] // {})
                | .hasTrustDialogAccepted        = true
                | .hasCompletedProjectOnboarding = true
            ))
        ')"
    done
fi

if [[ "$(printf '%s' "$current"  | jq -S .)" != \
      "$(printf '%s' "$desired"  | jq -S .)" ]]; then
    log "patching .claude.json (remoteControl=${REMOTE_CONTROL}, trusted paths: ${!trust_set[*]:-<none>})"
    tmp_file="$(mktemp)"
    printf '%s\n' "$desired" > "$tmp_file"
    install_for_target "$tmp_file" "$TARGET_JSON" 600
    rm -f "$tmp_file"
fi

# --- (4) settings.json: defaultMode + remoteControlAtStartup + skip flags
#       Realer logged-in Zustand zeigt: alle drei Keys leben hier, NICHT
#       in .claude.json. Die skip*-Flags unterdruecken die einmaligen
#       Opt-in-Dialoge fuer auto/bypassPermissions.
DEFAULT_MODE="${CLAUDE_DEFAULT_MODE:-}"

cur_settings="$(read_json_or_empty "$TARGET_SETTINGS")"
new_settings="$cur_settings"

# defaultMode: nur anfassen wenn Option nicht leer
if [[ -n "$DEFAULT_MODE" ]]; then
    new_settings="$(printf '%s' "$new_settings" | jq --arg mode "$DEFAULT_MODE" '
        .permissions = ((.permissions // {}) | .defaultMode = $mode)
    ')"

    # Pre-accept des Opt-in-Dialogs fuer den jeweiligen Modus.
    case "$DEFAULT_MODE" in
        auto)
            new_settings="$(printf '%s' "$new_settings" | jq '.skipAutoPermissionPrompt = true')"
            ;;
        bypassPermissions)
            new_settings="$(printf '%s' "$new_settings" | jq '.skipDangerousModePermissionPrompt = true')"
            ;;
    esac
fi

# remoteControlAtStartup: idempotent setzen oder entfernen
if [[ "$REMOTE_CONTROL" == "true" ]]; then
    new_settings="$(printf '%s' "$new_settings" | jq '.remoteControlAtStartup = true')"
else
    # Explizit entfernen — sonst bleibt auf persistent volumes nach einem
    # frueheren remoteControl=true die Auto-Registrierung haengen.
    new_settings="$(printf '%s' "$new_settings" | jq 'del(.remoteControlAtStartup)')"
fi

if [[ "$(printf '%s' "$cur_settings" | jq -S .)" != \
      "$(printf '%s' "$new_settings" | jq -S .)" ]]; then
    log "patching ${TARGET_SETTINGS} (defaultMode=${DEFAULT_MODE:-<unchanged>}, remoteControl=${REMOTE_CONTROL})"
    tmp_file="$(mktemp)"
    printf '%s\n' "$new_settings" > "$tmp_file"
    install_for_target "$tmp_file" "$TARGET_SETTINGS" 600
    rm -f "$tmp_file"
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
