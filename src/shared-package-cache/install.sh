#!/bin/bash
set -e
USERNAME="${USERNAME:-"${_REMOTE_USER:-"automatic"}"}"
CACHEDIR="${CACHEDIR:-"/var/package-cache"}"
GO_ENABLED="${GO:-"true"}"
NPM_ENABLED="${NPM:-"true"}"

if [ "$(id -u)" -ne 0 ]; then
  echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
  exit 1
fi

if [ "${USERNAME}" = "auto" ] || [ "${USERNAME}" = "automatic" ]; then
  USERNAME=""
  POSSIBLE_USERS=("vscode" "node" "codespace" "$(awk -v val=1000 -F ":" '$3==val{print $1}' /etc/passwd)")
  for CURRENT_USER in "${POSSIBLE_USERS[@]}"; do
    if id -u "${CURRENT_USER}" > /dev/null 2>&1; then
      USERNAME=${CURRENT_USER}
      break
    fi
  done
  if [ "${USERNAME}" = "" ]; then
    USERNAME=root
  fi
elif [ "${USERNAME}" = "none" ] || ! id -u "${USERNAME}" > /dev/null 2>&1; then
  USERNAME=root
fi

groupadd -f package_cache_group

tee /usr/local/share/shared-package-cache-init.sh > /dev/null \
<< EOF
#!/usr/bin/env bash
set -e

sudoIf()
{
  if [ "\$(id -u)" -ne 0 ]; then
    sudo "\$@"
  else
    "\$@"
  fi
}

if [ ! -d "${CACHEDIR}" ]; then
  sudoIf mkdir -p "${CACHEDIR}"
fi

if [ "${GO_ENABLED}" == "true" ]; then
  if type go &> /dev/null; then
    echo "Activating GO mod cache sharing"
    if [ ! -d "${CACHEDIR}/go" ]; then
      sudoIf mkdir -p "${CACHEDIR}/go"
    fi
    sudoIf ln -sf "${GOPATH}/pkg/mod" "${CACHEDIR}/go"
  else
    echo "Go mod cache sharing is disabled since Go is not installed"
  fi
fi

if [ "${NPM_ENABLED}" == "true" ]; then
  if type npm &> /dev/null; then
    echo "Activating NPM package cache sharing"
    if [ ! -d "${CACHEDIR}/npm" ]; then
      mkdir -p "${CACHEDIR}/npm"
    fi
    npm config set cache "${CACHEDIR}/npm" --global
  else
    echo "Npm package cache sharing is disabled since Npm is not installed"
  fi
else
  echo "NPM package cache sharing is disabled"
fi

sudoIf chgrp -R package_cache_group "${CACHEDIR}"
sudoIf chmod g+rw "${CACHEDIR}"

set +e
exec "\$@"
EOF

chmod +x /usr/local/share/shared-package-cache-init.sh
chown "${USERNAME}":root /usr/local/share/shared-package-cache-init.sh