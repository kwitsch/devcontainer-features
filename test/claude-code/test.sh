#!/bin/bash
# Default test — Feature mit Standard-Optionen installiert.
# Wird vom `devcontainer features test` Autorun-Mechanismus aufgerufen.
#
# CI stubt $HOME/.claude.json + $HOME/.claude/.credentials.json mit
# minimalen valid-JSON-Dummies (siehe .github/workflows/test.yaml), damit
# postCreate/postStart ihren Happy-Path durchlaufen. Echte Marketplace-/
# Plugin-Installs werden trotzdem nicht erreicht (kein Login).
#
# Verifiziert werden:
#   - Build-Time-Artefakte: Cache-Binary, Lifecycle-Skripte, Tooling
#   - onCreate-Output: `claude install` Launcher unter ~/.local/bin/claude
#   - postCreate-Output: Credentials/.claude.json in Target-User-Home
#   - postStart-Output: workspace trust + defaultMode in den Config-Files

set -e

# Import test library — provides `check` and `reportResults`
source dev-container-features-test-lib

# --- Build-Time Artefakte -------------------------------------------------
check "jq installed" command -v jq
check "curl installed" command -v curl
check "sudo installed" command -v sudo

check "binary cached at /opt/claude-code/cache/claude" \
    test -f /opt/claude-code/cache/claude

check "VERSION marker exists" \
    test -s /opt/claude-code/cache/VERSION

check "lifecycle: _lib.sh present with mode 644" \
    bash -c 'test -f /usr/local/share/claude-code/_lib.sh && \
             [ "$(stat -c %a /usr/local/share/claude-code/_lib.sh)" = "644" ]'

check "lifecycle: onCreate.sh executable" \
    test -x /usr/local/share/claude-code/onCreate.sh

check "lifecycle: postCreate.sh executable" \
    test -x /usr/local/share/claude-code/postCreate.sh

check "lifecycle: postStart.sh executable" \
    test -x /usr/local/share/claude-code/postStart.sh

# --- PATH-Vererbung -------------------------------------------------------
# Negative assertion: the legacy /opt/claude-code/bin path (used in v0.2)
# must not have leaked into /etc/environment. `! grep -q` returns success
# iff the pattern is absent; if /etc/environment is missing, grep exits 2
# and the negation still passes — which is the right outcome here.
check "no /opt/claude-code/bin leftover in /etc/environment" \
    bash -c '! grep -q "/opt/claude-code/bin" /etc/environment 2>/dev/null'

# --- onCreate-Resultat: claude installiert pro User -----------------------
# Resolver-Logik aus _lib.sh inline: erster non-root, login-faehiger User
TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ \
    { print $3":"$1 }' /etc/passwd | sort -n | head -n1 | cut -d: -f2)"
check "target user resolved" test -n "$TARGET_USER"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
check "target user has home" test -d "$TARGET_HOME"

check "claude launcher installed in target user home" \
    test -x "${TARGET_HOME}/.local/bin/claude"

# Invoke the launcher directly — the test script may not run as root
# (image metadata can pin remoteUser to a non-root account), in which
# case `su -` would prompt for a password.
check "claude launcher executes via direct path" \
    "${TARGET_HOME}/.local/bin/claude" --version

# --- postStart-Resultat: .claude.json + settings.json patches -------------
# Default-Optionen (v1.3+): channel=latest, remoteControl=true,
#   defaultMode="" (host wins; stub host has none → key absent),
#   theme=""      (host wins; stub host has none → safety net → "dark").
check "workspace trust applied to .claude.json" \
    bash -c "jq -e '.projects | to_entries | length > 0' '${TARGET_HOME}/.claude.json'"

# Regression guard: ensure the workspace key is an actual absolute path
# (existed once as literal '$containerWorkspaceFolder' when the obsolete
# containerEnv substitution was still in the manifest).
check "workspace trust key is an absolute path (no \$ substitution leftover)" \
    bash -c 'jq -e ".projects | keys | map(startswith(\"/\") and (contains(\"\$\") | not)) | all" "'"${TARGET_HOME}"'/.claude.json"'

check "remoteDialogSeen = true in .claude.json (default)" \
    bash -c "jq -e '.remoteDialogSeen == true' '${TARGET_HOME}/.claude.json'"

check "remoteControlAtStartup = true in settings.json (default)" \
    bash -c "jq -e '.remoteControlAtStartup == true' '${TARGET_HOME}/.claude/settings.json'"

# defaultMode="" → Feature darf permissions.defaultMode nicht setzen.
# `claude install` koennte settings.json mit eigenen defaults anlegen, deshalb
# wird auf "key absent or not equal to a Feature-only value" geprueft.
check "settings.json has no permissions.defaultMode when option is empty (default)" \
    bash -c "
        if [ -f '${TARGET_HOME}/.claude/settings.json' ]; then
            jq -e '(.permissions.defaultMode // null) == null' '${TARGET_HOME}/.claude/settings.json'
        fi
    "

check "settings.json has no skipAutoPermissionPrompt when defaultMode is empty (default)" \
    bash -c "
        if [ -f '${TARGET_HOME}/.claude/settings.json' ]; then
            jq -e '(.skipAutoPermissionPrompt // null) != true' '${TARGET_HOME}/.claude/settings.json'
        fi
    "

# --- Wizard-Suppression: erstes `claude` darf keinen Wizard zeigen --------
check "hasCompletedOnboarding = true in .claude.json (default)" \
    bash -c "jq -e '.hasCompletedOnboarding == true' '${TARGET_HOME}/.claude.json'"

# Host-Stub hat kein theme → safety net in postStart forciert "dark".
check "theme = 'dark' in .claude.json (safety net, host stub has no theme)" \
    bash -c "jq -e '.theme == \"dark\"' '${TARGET_HOME}/.claude.json'"

check "firstStartTime set in .claude.json" \
    bash -c "jq -e '(.firstStartTime // 0) > 0' '${TARGET_HOME}/.claude.json'"

# --- User-CLAUDE.md: hostClaudeMerge=true (default) merges host stub ------
# CI workflow stubs $HOME/.claude/CLAUDE.md on the runner before invoking
# `devcontainer features test`, so the bind mount carries the marker into
# /host_claude/.claude/CLAUDE.md and apply_user_claude_md should copy it.
check "user CLAUDE.md exists in target home (default merge)" \
    test -f "${TARGET_HOME}/.claude/CLAUDE.md"

check "user CLAUDE.md is owned by target user" \
    bash -c '[[ "$(stat -c %U "'"${TARGET_HOME}"'/.claude/CLAUDE.md")" = "'"${TARGET_USER}"'" ]]'

check "user CLAUDE.md contains the host stub marker" \
    grep -q "ci-stub-host-memory" "${TARGET_HOME}/.claude/CLAUDE.md"

# --- resolve_release_channel: smoke tests ---------------------------------
# Sourced after `claude install` ran, so config.env reflects the persisted
# Feature options. We swap HOST_CLAUDE_MOUNT to point at temp fixtures.
check "resolve_release_channel falls back to 'latest' without host setting" \
    bash -c '
        d="$(mktemp -d)"
        mkdir -p "$d/.claude" && printf "{}" > "$d/.claude/settings.json"
        . /usr/local/share/claude-code/_lib.sh
        export HOST_CLAUDE_MOUNT="$d" CLAUDE_CHANNEL=""
        [ "$(resolve_release_channel)" = "latest" ]
    '

check "resolve_release_channel picks 'stable' from host autoUpdatesChannel" \
    bash -c '
        d="$(mktemp -d)"
        mkdir -p "$d/.claude"
        printf "{\"autoUpdatesChannel\": \"stable\"}" > "$d/.claude/settings.json"
        . /usr/local/share/claude-code/_lib.sh
        export HOST_CLAUDE_MOUNT="$d" CLAUDE_CHANNEL=""
        [ "$(resolve_release_channel)" = "stable" ]
    '

check "resolve_release_channel: CLAUDE_CHANNEL override beats host setting" \
    bash -c '
        d="$(mktemp -d)"
        mkdir -p "$d/.claude"
        printf "{\"autoUpdatesChannel\": \"stable\"}" > "$d/.claude/settings.json"
        . /usr/local/share/claude-code/_lib.sh
        export HOST_CLAUDE_MOUNT="$d" CLAUDE_CHANNEL="latest"
        [ "$(resolve_release_channel)" = "latest" ]
    '

# Report result
reportResults
