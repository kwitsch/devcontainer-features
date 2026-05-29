#!/bin/bash
# Scenario: claudeMd is set, hostClaudeMerge=false. Verifies that
# apply_user_claude_md writes the option content (only) to the target
# user's ~/.claude/CLAUDE.md, even without a host CLAUDE.md.

set -e
source dev-container-features-test-lib

TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ \
    { print $3":"$1 }' /etc/passwd | sort -n | head -n1 | cut -d: -f2)"

check "target user was discovered" test -n "$TARGET_USER"

# Options are persisted to the Feature's config.env (sourced by every
# lifecycle hook). containerEnv cannot carry them directly because
# ${templateOption:...} is template syntax and not substituted in features.
check "CLAUDE_CLAUDEMD was persisted to config.env" \
    bash -c '. /usr/local/share/claude-code/config.env && [ -n "${CLAUDE_CLAUDEMD:-}" ]'

check "CLAUDE_HOST_CLAUDE_MERGE was persisted as false" \
    bash -c '. /usr/local/share/claude-code/config.env && [ "${CLAUDE_HOST_CLAUDE_MERGE:-}" = "false" ]'

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_MD="${TARGET_HOME}/.claude/CLAUDE.md"

check "CLAUDE.md exists in target home" test -f "$TARGET_MD"

# Ownership: file must belong to the target user, not root — otherwise
# `claude` running as the user could not edit it later without sudo.
check "CLAUDE.md is owned by target user" \
    bash -c '[[ "$(stat -c %U "'"$TARGET_MD"'")" = "'"$TARGET_USER"'" ]]'

check "CLAUDE.md contains option content" \
    grep -q "Hello from option" "$TARGET_MD"

# Sanity: hostClaudeMerge=false honored. The test harness has no
# /host_claude/.claude/CLAUDE.md anyway, so the apply step's host branch
# must have been skipped. A guard against accidental fall-through.
check "CLAUDE.md does not pick up host content marker" \
    bash -c '! grep -q "ci-stub-host-memory" "'"$TARGET_MD"'"'

reportResults
