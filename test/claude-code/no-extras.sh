#!/bin/bash
# Scenario: defaultMode="" (skip), remoteControl=false, remoteControlServer=false
# Verifies that .claude.json gets only workspace trust (no remoteControlAtStartup)
# and settings.json is NOT touched.

set -e
source dev-container-features-test-lib

TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ \
    { print $3":"$1 }' /etc/passwd | sort -n | head -n1 | cut -d: -f2)"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

check "settings.json NOT created when defaultMode is empty" \
    bash -c "! test -f '${TARGET_HOME}/.claude/settings.json'"

check ".claude.json has no remoteControlAtStartup when remoteControl=false" \
    bash -c "jq -e '(.remoteControlAtStartup // null) != true' \
             '${TARGET_HOME}/.claude.json'"

# Workspace trust remains active (immer aktiv, kein Toggle)
check "workspace trust still applied" \
    bash -c "jq -e '.projects | to_entries | length > 0' \
             '${TARGET_HOME}/.claude.json'"

check "no remote-control daemon spawned (server option off)" \
    bash -c "! test -f '${TARGET_HOME}/.claude/remote-control.pid'"

reportResults
