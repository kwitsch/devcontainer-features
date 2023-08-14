#!/bin/bash
set -e
GO_ENABLED="${GO:-"true"}"
NPM_ENABLED="${NPM:-"true"}"
USERNAME="${USERNAME:-"${_REMOTE_USER:-"automatic"}"}"
USERGROUP="package_cache_group"
USERNAMEANDGROUP="${USERNAME}:${USERGROUP}"
CACHE_DIR="${CACHEDIR:-"/var/package-cache"}"
GO_DIR="${CACHE_DIR}/go"
NPM_DIR="${CACHE_DIR}/npm"

echo "${CACHEDIR} vs ${CACHE_DIR}"

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

groupadd -f "${USERGROUP}"

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

if [ ! -d "${CACHE_DIR}" ]; then
  sudoIf mkdir -p "${CACHE_DIR}"
fi

if [ "${GO_ENABLED}" == "true" ]; then
  if type go &> /dev/null; then
    echo "Activating GO mod cache sharing"
    if [ ! -d "${GO_DIR}" ]; then
      sudoIf mkdir -p "${GO_DIR}"
    fi
    sudoIf chown -R "${USERNAMEANDGROUP}" "${GO_DIR}"
    sudoIf ln -sf "${GOPATH}/pkg/mod" "${GO_DIR}"
  else
    echo "Go mod cache sharing is disabled since Go is not installed"
  fi
fi

if [ "${NPM_ENABLED}" == "true" ]; then
  if type npm &> /dev/null; then
    echo "Activating NPM package cache sharing"
    if [ ! -d "${NPM_DIR}" ]; then
      sudoIf mkdir -p "${NPM_DIR}"
    fi
    sudoIf chown -R "${USERNAMEANDGROUP}" "${NPM_DIR}"
    npm config set cache "${NPM_DIR}" --global
  else
    echo "Npm package cache sharing is disabled since Npm is not installed"
  fi
else
  echo "NPM package cache sharing is disabled"
fi

sudoIf chmod g+rw "${CACHE_DIR}"

set +e
exec "\$@"
EOF

chmod +x /usr/local/share/shared-package-cache-init.sh
chown "${USERNAMEANDGROUP}" /usr/local/share/shared-package-cache-init.sh