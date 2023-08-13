#!/bin/bash

set -e

# shellcheck disable=SC1091
source dev-container-features-test-lib

check "test if go folder does not exist" sh -c 'find /tmp/package-cache/go -type d &>/dev/null && false || true'

reportResults