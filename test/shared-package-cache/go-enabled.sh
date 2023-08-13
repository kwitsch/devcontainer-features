#!/bin/bash

set -e

# shellcheck disable=SC1091
source dev-container-features-test-lib

check "test if go folder exists" find /tmp/package-cache/go -type d &>/dev/null

reportResults