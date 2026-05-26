#!/bin/bash
# Scenario: defaultMode="" (skip), remoteControl=false, remoteControlServer=false
# Verifies that .claude.json gets only workspace trust (no remoteDialogSeen),
# and settings.json is NOT touched (no defaultMode, no remoteControlAtStartup,
# no skip*Permission flags from this Feature).

set -e
source dev-container-features-test-lib

TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ \
    { print $3":"$1 }' /etc/passwd | sort -n | head -n1 | cut -d: -f2)"
check "target user resolved" test -n "$TARGET_USER"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

# `claude install` may create settings.json with its own defaults — that's
# fine. The Feature contract is: when defaultMode="" and remoteControl=false
# we don't *set* any of these keys; they may exist with other values from
# the upstream installer but must not equal the Feature's "on" state.
check "settings.json has no permissions.defaultMode when option is empty" \
    bash -c "
        if [ -f '${TARGET_HOME}/.claude/settings.json' ]; then
            jq -e '(.permissions.defaultMode // null) == null' '${TARGET_HOME}/.claude/settings.json'
        fi
    "

check "settings.json has no remoteControlAtStartup when remoteControl=false" \
    bash -c "
        if [ -f '${TARGET_HOME}/.claude/settings.json' ]; then
            jq -e '(.remoteControlAtStartup // null) != true' '${TARGET_HOME}/.claude/settings.json'
        fi
    "

check "settings.json has no skipAutoPermissionPrompt when defaultMode is empty" \
    bash -c "
        if [ -f '${TARGET_HOME}/.claude/settings.json' ]; then
            jq -e '(.skipAutoPermissionPrompt // null) != true' '${TARGET_HOME}/.claude/settings.json'
        fi
    "

check ".claude.json has no remoteDialogSeen when remoteControl=false" \
    bash -c "jq -e '(.remoteDialogSeen // null) != true' \
             '${TARGET_HOME}/.claude.json'"

# Workspace trust remains active (immer aktiv, kein Toggle)
check "workspace trust still applied" \
    bash -c "jq -e '.projects | to_entries | length > 0' \
             '${TARGET_HOME}/.claude.json'"

check "no remote-control daemon spawned (server option off)" \
    bash -c "! test -f '${TARGET_HOME}/.claude/remote-control.pid'"

reportResults
