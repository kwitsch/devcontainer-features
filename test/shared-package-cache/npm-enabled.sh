#!/bin/bash

set -e

# shellcheck disable=SC1091
source dev-container-features-test-lib

check "test if npm folder exists" find /tmp/package-cache/npm -type d &>/dev/null

reportResults