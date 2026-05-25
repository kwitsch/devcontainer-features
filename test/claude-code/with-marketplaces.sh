#!/bin/bash
# Scenario: marketplaces option is set to "anthropics/claude-code"
# We cannot reliably verify the network call to `claude plugin marketplace add`
# (network unavailable / private package, etc.), but we CAN verify that the
# environment variable was passed through correctly to postCreate.

set -e
source dev-container-features-test-lib

TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ \
    { print $3":"$1 }' /etc/passwd | sort -n | head -n1 | cut -d: -f2)"

# Without this gate, an empty TARGET_USER would call `getent passwd ""`,
# which returns every entry and resolves TARGET_HOME to /root by accident.
check "target user was discovered" test -n "$TARGET_USER"

# The option value is persisted to the Feature's config.env (sourced by
# every lifecycle hook). containerEnv cannot carry it directly because
# ${templateOption:...} is template syntax and not substituted in features.
check "CLAUDE_MARKETPLACES was persisted to config.env" \
    bash -c '. /usr/local/share/claude-code/config.env && [ -n "${CLAUDE_MARKETPLACES:-}" ]'

check "CLAUDE_MARKETPLACES contains anthropics/claude-code" \
    bash -c '. /usr/local/share/claude-code/config.env && [[ "${CLAUDE_MARKETPLACES:-}" == *"anthropics/claude-code"* ]]'

# Plugin store directory should exist or be ready to be created.
# (We don't assert successful marketplace add because postCreate's
# credential-setup soft-fails without a host mount, which short-circuits
# the marketplace-add section — see postCreate.sh.)
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
check "target home accessible" test -d "$TARGET_HOME"

reportResults
