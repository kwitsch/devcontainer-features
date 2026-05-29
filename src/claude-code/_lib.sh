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

# --- Workspace-Folder ermitteln -------------------------------------------
# Lifecycle-Skripte laufen per Devcontainer-Spec mit cwd = workspaceFolder,
# also ist $PWD die primaere Quelle. `containerEnv.${containerWorkspaceFolder}`
# wird vom Feature-Manifest aus NICHT substituiert (Docker emittiert
# UndefinedVar und setzt die ENV auf leer/literal), daher hier kein Lookup
# auf eine Feature-eigene ENV-Variable.
#
# Sanity-Checks:
#   - absoluter Pfad, der existiert
#   - kein literales "${...}" (Substitution-Reste)
#   - nicht /
#
# Echoes den aufgeloesten Pfad oder leer, wenn nichts Vernuenftiges gefunden
# wurde.
resolve_workspace_folder() {
    local cand
    for cand in "${1:-}" "${PWD:-}"; do
        [[ -z "$cand" ]] && continue
        [[ "$cand" == \$* || "$cand" == \${* ]] && continue
        [[ "$cand" == /* ]] || continue
        [[ "$cand" == "/" ]] && continue
        [[ -d "$cand" ]] || continue
        printf '%s' "$cand"
        return 0
    done

    # Letzter Ausweg: /workspaces/<single-dir> — Standard-Mountpunkt
    # in VS Code / Codespaces Dev Containers.
    if [[ -d /workspaces ]]; then
        local found="" entry
        for entry in /workspaces/*/; do
            [[ -d "$entry" ]] || continue
            if [[ -n "$found" ]]; then
                # mehrere Kandidaten — nicht raten
                printf ''
                return 0
            fi
            found="${entry%/}"
        done
        [[ -n "$found" ]] && printf '%s' "$found"
    fi
}

# --- Workspace-Trust auf alle /workspaces/* anwenden ----------------------
# Schreibt .projects[<subdir>] = { hasTrustDialogAccepted: true,
# hasCompletedProjectOnboarding: true } in TARGET_JSON fuer jeden
# unmittelbaren Unterordner von /workspaces. Idempotent.
#
# Wird sowohl aus postCreate.sh als auch postStart.sh aufgerufen — beim
# Create steht .claude.json u.U. noch nicht (z.B. weil Host-Creds fehlen
# und postCreate frueh exitet); deshalb startet das Skript notfalls von
# einem leeren JSON-Objekt und legt die Datei selbst an.
#
# Voraussetzung: resolve_target_paths wurde vorher aufgerufen
# (TARGET_JSON / TARGET_USER muessen gesetzt sein).
apply_workspace_trust() {
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not available — workspace-trust skipped"
        return 0
    fi
    if [[ -z "${TARGET_JSON:-}" ]]; then
        warn "TARGET_JSON not set — call resolve_target_paths first"
        return 0
    fi
    if [[ ! -d /workspaces ]]; then
        log "no /workspaces directory — workspace-trust skipped"
        return 0
    fi

    local trust_paths=() d
    for d in /workspaces/*/; do
        if [[ -d "$d" ]]; then trust_paths+=("${d%/}"); fi
    done

    if [[ ${#trust_paths[@]} -eq 0 ]]; then
        log "no /workspaces/*/ subdirs found — workspace-trust skipped"
        return 0
    fi

    local current desired
    if [[ -f "$TARGET_JSON" ]] && jq -e . "$TARGET_JSON" >/dev/null 2>&1; then
        current="$(cat "$TARGET_JSON")"
    else
        current='{}'
    fi
    desired="$current"

    local p
    for p in "${trust_paths[@]}"; do
        desired="$(printf '%s' "$desired" | jq --arg ws "$p" '
            .projects = ((.projects // {}) | .[$ws] = ((.[$ws] // {})
                | .hasTrustDialogAccepted        = true
                | .hasCompletedProjectOnboarding = true
            ))
        ')"
    done

    if [[ "$(printf '%s' "$current" | jq -S .)" != \
          "$(printf '%s' "$desired" | jq -S .)" ]]; then
        log "applying workspace-trust for: ${trust_paths[*]}"
        local tmp; tmp="$(mktemp)"
        printf '%s\n' "$desired" > "$tmp"
        install_for_target "$tmp" "$TARGET_JSON" 600
        rm -f "$tmp"
    fi
}

# --- User-CLAUDE.md zusammensetzen ----------------------------------------
# Schreibt ${TARGET_DIR}/CLAUDE.md aus zwei Quellen:
#   (1) CLAUDE_CLAUDEMD            — literal Option-Inhalt (wenn non-empty)
#   (2) ${HOST_DIR}/.claude/CLAUDE.md — wenn CLAUDE_HOST_CLAUDE_MERGE=true
#                                       und Datei via Bind-Mount lesbar ist
# Trennung zwischen Option-Block und Host-Block: eine Leerzeile ("\n\n").
#
# Beide Quellen leer/abwesend → Funktion no-op (bestehende Container-Datei
# wird NICHT angefasst).
#
# Idempotent: aus postCreate UND postStart aufgerufen; vergleicht den
# berechneten Body mit dem on-disk Inhalt und schreibt nur bei Diff.
#
# Voraussetzung: resolve_target_paths wurde vorher aufgerufen
# (TARGET_USER / TARGET_HOME / TARGET_DIR muessen gesetzt sein).
# HOST_DIR wird optional aus dem Caller-Scope uebernommen; sonst Fallback
# auf den Standard-Mount-Pfad (containerEnv setzt HOST_CLAUDE_MOUNT).
apply_user_claude_md() {
    if [[ -z "${TARGET_DIR:-}" ]]; then
        warn "TARGET_DIR not set — call resolve_target_paths first"
        return 0
    fi

    local host_md="${HOST_DIR:-${HOST_CLAUDE_MOUNT:-/host_claude}}/.claude/CLAUDE.md"
    local opt="${CLAUDE_CLAUDEMD:-}"
    local merge="${CLAUDE_HOST_CLAUDE_MERGE:-true}"
    local body=""
    local used_host="no"

    if [[ -n "$opt" ]]; then
        body="$opt"
    fi

    if [[ "$merge" == "true" && -r "$host_md" ]]; then
        local host_content
        host_content="$(cat "$host_md")"
        if [[ -n "$body" ]]; then
            body="${body}"$'\n\n'"${host_content}"
        else
            body="$host_content"
        fi
        used_host="yes"
    fi

    if [[ -z "$body" ]]; then
        log "no CLAUDE.md content (option empty, host merge disabled or host file absent) — skipping"
        return 0
    fi

    local dst="${TARGET_DIR}/CLAUDE.md"

    # Idempotenz: bei identischem on-disk Inhalt nicht schreiben.
    # `$(cat …)` strippt trailing newlines — `printf '%s\n'` unten schreibt
    # genau einen Trailing-Newline, also matched der Vergleich gegen den
    # in-memory body.
    if [[ -f "$dst" ]] && [[ "$(cat "$dst")" == "$body" ]]; then
        log "${dst} up-to-date — skipping"
        return 0
    fi

    # TARGET_DIR sicherstellen + harden (idempotent — postCreate's
    # credential-install Block macht das spaeter ohnehin nochmal).
    mkdir -p "$TARGET_DIR"
    chmod 700 "$TARGET_DIR"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown "${TARGET_USER}:${TARGET_USER}" "$TARGET_DIR"
    fi

    local tmp; tmp="$(mktemp)"
    printf '%s\n' "$body" > "$tmp"
    install_for_target "$tmp" "$dst" 644
    rm -f "$tmp"

    local opt_marker
    if [[ -n "$opt" ]]; then opt_marker="yes"; else opt_marker="no"; fi
    log "wrote ${dst} (option=${opt_marker}, hostMerge=${used_host})"
}

# --- Release-Channel ermitteln --------------------------------------------
# Praezedenz:
#   (1) Feature-Option CLAUDE_CHANNEL (wenn non-empty) — Override
#   (2) Host-Settings `~/.claude/settings.json` Feld `autoUpdatesChannel`
#       (Claude Code persistiert hier die Wahl von `claude install <channel>`;
#        Binary-Strings: "Saved autoUpdatesChannel= ... to user settings")
#   (3) Fallback "latest" — gilt fuer Codespaces-Prebuilds (kein Host-Mount)
#       oder Hosts, die den Wert nicht gesetzt haben.
#
# Akzeptierte Werte: "stable" | "latest". Andere Werte werden verworfen und
# fallen auf den naechsten Schritt durch.
resolve_release_channel() {
    local override="${CLAUDE_CHANNEL:-}"
    case "$override" in
        stable|latest) printf '%s' "$override"; return ;;
    esac

    local host_settings="${HOST_CLAUDE_MOUNT:-/host_claude}/.claude/settings.json"
    if command -v jq >/dev/null 2>&1 && [[ -r "$host_settings" ]] && \
       jq -e . "$host_settings" >/dev/null 2>&1; then
        local val
        val="$(jq -r '.autoUpdatesChannel // empty' "$host_settings" 2>/dev/null || true)"
        case "$val" in
            stable|latest) printf '%s' "$val"; return ;;
        esac
    fi

    printf 'latest'
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
