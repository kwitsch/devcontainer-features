#!/bin/bash

set -e

# shellcheck disable=SC1091
source dev-container-features-test-lib

check "test if npm folder does not exist" sh -c 'find /tmp/package-cache/npm -type d &>/dev/null && false || true'

reportResults