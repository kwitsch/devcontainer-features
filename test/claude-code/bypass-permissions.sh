#!/bin/bash
# Scenario: defaultMode = "bypassPermissions"
# Verifies that an explicitly set mode is written to settings.json (host wizard
# state would otherwise win since the default is now empty).

set -e
source dev-container-features-test-lib

TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ \
    { print $3":"$1 }' /etc/passwd | sort -n | head -n1 | cut -d: -f2)"
check "target user resolved" test -n "$TARGET_USER"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

check "settings.json exists" \
    test -f "${TARGET_HOME}/.claude/settings.json"

check "permissions.defaultMode = 'bypassPermissions'" \
    bash -c "jq -e '.permissions.defaultMode == \"bypassPermissions\"' \
             '${TARGET_HOME}/.claude/settings.json'"

check "skipDangerousModePermissionPrompt = true (pre-accept bypass opt-in)" \
    bash -c "jq -e '.skipDangerousModePermissionPrompt == true' \
             '${TARGET_HOME}/.claude/settings.json'"

check "skipAutoPermissionPrompt NOT set (only auto-mode adds it)" \
    bash -c "jq -e '(.skipAutoPermissionPrompt // null) != true' \
             '${TARGET_HOME}/.claude/settings.json'"

reportResults
