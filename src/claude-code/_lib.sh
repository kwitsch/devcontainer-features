#!/usr/bin/env bash
# _lib.sh — gemeinsame Helpers fuer claude-code Lifecycle-Skripte.
#
# Verwendung (in jedem Skript, *bevor* andere Logik laeuft):
#     SCRIPT_TAG="claude-setup"
#     . "$(dirname "$(readlink -f "$0")")/_lib.sh"
#
# Dieses Skript wird per `source`/`.` eingebunden — NICHT direkt ausfuehren.
# Es setzt `set -euo pipefail` *nicht* selbst; das ist Verantwortung des
# einbindenden Skripts.

# --- Logging ---------------------------------------------------------------
log()  { printf '[%s] %s\n'        "${SCRIPT_TAG:-claude}" "$*"; }
warn() { printf '[%s] WARN: %s\n'  "${SCRIPT_TAG:-claude}" "$*" >&2; }
fail() { printf '[%s] ERROR: %s\n' "${SCRIPT_TAG:-claude}" "$*" >&2; exit 1; }

# --- Runtime-Config laden -------------------------------------------------
# Option-Werte sind im containerEnv des Feature-Manifests nicht
# substituierbar (${templateOption:...} ist Template-Syntax, nicht
# Feature-Syntax). install.sh schreibt die Werte daher in eine Datei,
# die wir hier sourcen — vor jeder anderen Logik, damit CLAUDE_*-Vars
# fuer alle nachfolgenden Funktionen verfuegbar sind.
if [[ -f /usr/local/share/claude-code/config.env ]]; then
    # shellcheck disable=SC1091
    . /usr/local/share/claude-code/config.env
fi

# --- Target-User-Erkennung -------------------------------------------------
# Erster non-root login-faehiger User aus /etc/passwd (lowest UID >= 1000,
# < 65534, shell endet nicht auf nologin|false). Echoes username or empty.
detect_target_user() {
    awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ \
             { print $3":"$1 }' /etc/passwd \
        | sort -n | head -n1 | cut -d: -f2
}

# Setzt die globalen Variablen:
#   TARGET_USER, TARGET_HOME, TARGET_DIR, TARGET_CREDS, TARGET_JSON, TARGET_SETTINGS
# Auflosung-Reihenfolge: CLAUDE_TARGET_USER (Override) -> Auto-Detect.
# Bei Fehlern: fail.
resolve_target_paths() {
    TARGET_USER="${CLAUDE_TARGET_USER:-}"
    if [[ -z "$TARGET_USER" ]]; then
        TARGET_USER="$(detect_target_user)"
        [[ -n "$TARGET_USER" ]] || fail "no non-root login-capable user found in /etc/passwd"
        log "auto-detected target user: ${TARGET_USER}"
    fi
    id "$TARGET_USER" >/dev/null 2>&1 || fail "user '${TARGET_USER}' does not exist"

    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] \
        || fail "could not resolve home for '${TARGET_USER}'"

    TARGET_DIR="${TARGET_HOME}/.claude"
    TARGET_CREDS="${TARGET_DIR}/.credentials.json"
    TARGET_JSON="${TARGET_HOME}/.claude.json"
    TARGET_SETTINGS="${TARGET_DIR}/settings.json"
}

# --- Befehl als TARGET_USER ausfuehren ------------------------------------
# Verwendung: run_as_target /opt/claude-code/cache/claude install stable
# Strategien (in Reihenfolge):
#   1. bereits als TARGET_USER  -> direkter Aufruf
#   2. als root                 -> `su - <user> -c <quoted-cmd>` (Login-Shell)
#   3. mit passwordless sudo    -> `sudo -iu <user> -- <cmd>`
#   4. sonst                    -> fail
run_as_target() {
    [[ -n "${TARGET_USER:-}" ]] || fail "run_as_target called before resolve_target_paths"

    if [[ "$(id -un)" == "$TARGET_USER" ]]; then
        "$@"
    elif [[ "$(id -u)" -eq 0 ]]; then
        # printf %q quotet jedes argv-Element shell-sicher fuer su -c
        local quoted; quoted="$(printf ' %q' "$@")"
        su - "$TARGET_USER" -c "${quoted# }"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -iu "$TARGET_USER" -- "$@"
    else
        fail "cannot run as ${TARGET_USER} — current user $(id -un), no passwordless sudo"
    fi
}

# --- Atomares Installieren einer Datei in TARGET_USER-Pfade ---------------
# Schreibt nach mktemp im Zielverzeichnis, chmod/chown des Files, dann
# atomares mv. Beruehrt das Parent-Verzeichnis bewusst NICHT: postCreate.sh
# hardened ${TARGET_DIR} einmalig, und Pfade ausserhalb (z.B. ~/.claude.json
# direkt unter $HOME) sollen nicht ueberraschend chmod 700 / chown bekommen.
# Verwendung: install_for_target <src> <dst> <mode>  (mode z.B. 600)
install_for_target() {
    local src="$1" dst="$2" mode="$3"
    [[ -n "${TARGET_USER:-}" ]] || fail "install_for_target called before resolve_target_paths"

    local dir; dir="$(dirname "$dst")"
    # Wenn ${TARGET_DIR} fehlt (z.B. postCreate hat wegen fehlender
    # Host-Creds soft-skipped) und wir hier als root angekommen sind,
    # muss das Verzeichnis dem Target-User gehoeren — sonst kann er es
    # spaeter nicht beschreiben.
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        if [[ "$(id -u)" -eq 0 ]] && \
           [[ "$dir" == "${TARGET_DIR}" || "$dir" == "${TARGET_DIR}"/* ]]; then
            chmod 700 "$dir"
            chown "${TARGET_USER}:${TARGET_USER}" "$dir"
        fi
    fi

    local tmp; tmp="$(mktemp -p "$dir" .stage.XXXXXX)"
    cp "$src" "$tmp"
    chmod "$mode" "$tmp"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown "${TARGET_USER}:${TARGET_USER}" "$tmp"
    fi
    mv "$tmp" "$dst"      # atomar (gleiches Filesystem)
}

# Whitespace-Trim (leading + trailing) ohne externe Tools. Internal
# Whitespace bleibt erhalten — wichtig fuer Pfade mit Leerzeichen in
# Komma-Listen wie CLAUDE_MARKETPLACES / CLAUDE_PLUGINS.
trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# --- Hintergrund-Spawn als TARGET_USER ------------------------------------
# Startet einen Daemon-Prozess als TARGET_USER, detached vom Parent (nohup
# + closed stdin + output-redirect). Echoes die PID des Wrapper-Prozesses;
# return-code 0 bei Erfolg, 1 wenn kein Spawn-Pfad verfuegbar.
#
# Verwendung:
#   pid=$(run_as_target_background /path/to/log claude remote-control --spawn worktree)
#
# Die zurueckgegebene PID ist je nach Pfad:
#   - direkt:  PID des Befehls selbst
#   - su -c:   PID des nohup-Wrappers (wartet bis su zurueckkehrt;
#              `exec` im su-c-String vermeidet Zwischen-Shell)
#   - sudo:    PID des nohup-Wrappers (wartet bis sudo zurueckkehrt)
# In allen Faellen impliziert `kill -0 $pid` "Daemon laeuft noch".
run_as_target_background() {
    local logfile="$1"; shift
    [[ -n "${TARGET_USER:-}" ]] || fail "run_as_target_background called before resolve_target_paths"

    local pid
    if [[ "$(id -un)" == "$TARGET_USER" ]]; then
        nohup "$@" </dev/null >"$logfile" 2>&1 &
        pid=$!
        disown
    elif [[ "$(id -u)" -eq 0 ]]; then
        local quoted; quoted="$(printf ' %q' "$@")"
        nohup su - "$TARGET_USER" -c "exec${quoted}" \
            </dev/null >"$logfile" 2>&1 &
        pid=$!
        disown
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        nohup sudo -iu "$TARGET_USER" -- "$@" \
            </dev/null >"$logfile" 2>&1 &
        pid=$!
        disown
    else
        return 1
    fi
    echo "$pid"
}
