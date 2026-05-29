#!/bin/bash
# Scenario: useHostStatusbar = true
# Verifies the host statusLine is mirrored into the container settings.json and
# that the referenced ~/.claude/ script is symlinked from the read-only host
# mount. Depends on the CI host stub (.github/workflows/test.yaml) writing a
# ~/.claude/settings.json with statusLine + an executable ~/.claude/statusline.sh.

set -e
source dev-container-features-test-lib

TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ \
    { print $3":"$1 }' /etc/passwd | sort -n | head -n1 | cut -d: -f2)"
check "target user resolved" test -n "$TARGET_USER"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

check "settings.json exists" \
    test -f "${TARGET_HOME}/.claude/settings.json"

check "statusLine.command forwarded from host" \
    bash -c "jq -e '.statusLine.command == \"~/.claude/statusline.sh\"' \
             '${TARGET_HOME}/.claude/settings.json'"

check "statusLine.type forwarded from host" \
    bash -c "jq -e '.statusLine.type == \"command\"' \
             '${TARGET_HOME}/.claude/settings.json'"

check "statusline.sh is a symlink" \
    test -L "${TARGET_HOME}/.claude/statusline.sh"

check "symlink points into the host mount" \
    bash -c "test \"\$(readlink '${TARGET_HOME}/.claude/statusline.sh')\" \
             = '/host_claude/.claude/statusline.sh'"

reportResults
