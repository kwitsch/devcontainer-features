#!/bin/bash

set -e

# shellcheck disable=SC1091
source dev-container-features-test-lib

npm install -g hello-world-npm

ls -la /tmp/package-cache/npm

check "test if npm folder contains files" sh -c 'find /tmp/package-cache/npm -maxdepth 0 -type d &>/dev/null || find /tmp/package-cache/npm -maxdepth 0 -type f &>/dev/null'

reportResults