#!/bin/bash

set -e

# shellcheck disable=SC1091
source dev-container-features-test-lib

go install golang.org/x/tools/cmd/goimports@latest

ls -la /tmp/package-cache/go

check "test if go folder contains files" sh -c 'find /tmp/package-cache/go -maxdepth 0 -type d &>/dev/null || find /tmp/package-cache/go -maxdepth 0 -type f &>/dev/null'

reportResults