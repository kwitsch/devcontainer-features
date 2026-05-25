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

check "lifecycle: _lib.sh present (mode 644)" \
    test -f /usr/local/share/claude-code/_lib.sh

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

# --- postStart-Resultat: .claude.json patches -----------------------------
# Default-Optionen: remoteControl=true, defaultMode=auto
check "workspace trust applied to .claude.json" \
    bash -c "jq -e '.projects | to_entries | length > 0' '${TARGET_HOME}/.claude.json'"

check "remoteControlAtStartup = true in .claude.json (default)" \
    bash -c "jq -e '.remoteControlAtStartup == true' '${TARGET_HOME}/.claude.json'"

check "permissions.defaultMode = 'auto' in settings.json (default)" \
    bash -c "jq -e '.permissions.defaultMode == \"auto\"' '${TARGET_HOME}/.claude/settings.json'"

# Report result
reportResults
