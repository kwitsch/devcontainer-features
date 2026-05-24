#!/bin/bash
# Scenario: defaultMode = "bypassPermissions"
# Verifies that the chosen mode is written to settings.json instead of the default "auto".

set -e
source dev-container-features-test-lib

TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ \
    { print $3":"$1 }' /etc/passwd | sort -n | head -n1 | cut -d: -f2)"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

check "settings.json exists" \
    test -f "${TARGET_HOME}/.claude/settings.json"

check "permissions.defaultMode = 'bypassPermissions'" \
    bash -c "jq -e '.permissions.defaultMode == \"bypassPermissions\"' \
             '${TARGET_HOME}/.claude/settings.json'"

reportResults
