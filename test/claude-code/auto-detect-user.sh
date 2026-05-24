#!/bin/bash
# Scenario: targetUser="" → auto-detect on a Debian base image.
# Verifies the auto-detection resolves to a non-root login user (vscode by default
# in this image, after common-utils Feature has run).

set -e
source dev-container-features-test-lib

# Manual reproduction of detect_target_user logic
DETECTED="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ \
    { print $3":"$1 }' /etc/passwd | sort -n | head -n1 | cut -d: -f2)"

check "detect_target_user returns a username" test -n "$DETECTED"
check "detected user is not root" test "$DETECTED" != "root"
check "detected user has a real shell" \
    bash -c "getent passwd '${DETECTED}' | cut -d: -f7 | grep -Eq '(bash|zsh|sh|fish)$'"

# Verify the feature actually used this user
TARGET_HOME="$(getent passwd "$DETECTED" | cut -d: -f6)"
check "claude installed for auto-detected user" \
    test -x "${TARGET_HOME}/.local/bin/claude"

reportResults
