#!/usr/bin/env bash
# install.sh — Feature build-time hook (laeuft als root).
#
# Rolle: Image-Build-Zeit Pre-Warm-Cache fuer das Claude Code Binary.
#   - Laedt das aktuelle Binary nach /opt/claude-code/cache/claude
#   - Setzt KEINE PATH-Erweiterung (uebernimmt `claude install` in postCreate)
#   - Ruft `claude install` NICHT auf (das wuerde im Home von root landen)
#
# postCreate ruft anschliessend
#       /opt/claude-code/cache/claude install <channel>
# als Target-User auf — dieses Bootstrap-Binary kopiert sich nach
# ~/.local/share/claude/versions/<v>/ und legt den Launcher unter
# ~/.local/bin/claude an (hardcoded, vgl. anthropics/claude-code#21019).
#
# Download- und Verifikations-Logik 1:1 aus https://claude.ai/install.sh.

set -euo pipefail

FEATURE_DIR="/usr/local/share/claude-code"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

CC_CACHE_DIR="/opt/claude-code/cache"
CC_CACHE_BIN="${CC_CACHE_DIR}/claude"
CC_VERSION_FILE="${CC_CACHE_DIR}/VERSION"

# --- Helper: cross-distro Paket-Install ------------------------------------
pkg_install() {
    if   command -v apt-get  >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y --no-install-recommends "$@"
        rm -rf /var/lib/apt/lists/*
    elif command -v apk      >/dev/null 2>&1; then apk add --no-cache "$@"
    elif command -v microdnf >/dev/null 2>&1; then microdnf install -y "$@" && microdnf clean all
    elif command -v dnf      >/dev/null 2>&1; then dnf install -y "$@" && dnf clean all
    elif command -v yum      >/dev/null 2>&1; then yum install -y "$@" && yum clean all
    else
        echo "ERROR: no supported package manager for: $*" >&2; exit 1
    fi
}

# --- (1) Tooling: jq, curl, ca-certificates, sudo (fuer postCreate) -------
need=()
command -v jq   >/dev/null 2>&1 || need+=("jq")
command -v curl >/dev/null 2>&1 || need+=("curl" "ca-certificates")
command -v sudo >/dev/null 2>&1 || need+=("sudo")
[[ ${#need[@]} -gt 0 ]] && pkg_install "${need[@]}"

# --- (2) Plattform-Detektion (1:1 aus claude.ai/install.sh) ----------------
case "$(uname -s)" in
    Linux) ;;
    *) echo "ERROR: Feature only supports Linux containers (got $(uname -s))" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64)  arch="x64"   ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

if [ -f /lib/libc.musl-x86_64.so.1 ] \
   || [ -f /lib/libc.musl-aarch64.so.1 ] \
   || ldd /bin/ls 2>&1 | grep -q musl; then
    platform="linux-${arch}-musl"
else
    platform="linux-${arch}"
fi

# --- (3) Download + Checksum -----------------------------------------------
# Das Bootstrap fragt IMMER /latest ab (es gibt keinen /stable HTTP-Pfad);
# die Channel-Auswahl `stable|latest` kommt erst beim `claude install`
# Aufruf in postCreate ins Spiel.
DOWNLOAD_BASE_URL="https://downloads.claude.ai/claude-code-releases"
TMP_DIR="$(mktemp -d -t claude-code.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Resolving latest Claude Code version..."
version="$(curl -fsSL "${DOWNLOAD_BASE_URL}/latest")"
[[ -n "$version" ]] || { echo "ERROR: empty version response from ${DOWNLOAD_BASE_URL}/latest" >&2; exit 1; }

echo "==> Fetching manifest for ${version}/${platform}..."
manifest="$(curl -fsSL "${DOWNLOAD_BASE_URL}/${version}/manifest.json")"
checksum="$(printf '%s' "$manifest" | jq -r ".platforms[\"${platform}\"].checksum // empty")"
[[ "$checksum" =~ ^[a-f0-9]{64}$ ]] \
    || { echo "ERROR: no valid checksum for platform ${platform} (version ${version})" >&2; exit 1; }

echo "==> Downloading binary..."
tmp_bin="${TMP_DIR}/claude"
curl -fsSL -o "$tmp_bin" "${DOWNLOAD_BASE_URL}/${version}/${platform}/claude"

actual="$(sha256sum "$tmp_bin" | cut -d' ' -f1)"
[[ "$actual" == "$checksum" ]] \
    || { echo "ERROR: checksum mismatch (expected $checksum, got $actual)" >&2; exit 1; }

# --- (4) Cache ablegen (world-read+exec, kein PATH-Eintrag) ---------------
# Mode 0755: das Cache-Binary muss vom Target-User aufgerufen werden koennen
# (`claude install`). World-exec ist OK weil der Cache nur als Bootstrap-
# Quelle dient — der "produktive" claude-Aufruf erfolgt ueber den von
# `claude install` angelegten Launcher in ~/.local/bin/claude.
install -d -m 0755 "$CC_CACHE_DIR"
install -m 0755 "$tmp_bin" "$CC_CACHE_BIN"
echo "$version" > "$CC_VERSION_FILE"
chmod 0644 "$CC_VERSION_FILE"
echo "==> Cached claude ${version} at ${CC_CACHE_BIN}"

# --- (5) Lifecycle-Skripte + Library --------------------------------------
install -d -m 0755 "$FEATURE_DIR"
install -m 0644 "$SRC_DIR/_lib.sh"       "$FEATURE_DIR/_lib.sh"
install -m 0755 "$SRC_DIR/onCreate.sh"   "$FEATURE_DIR/onCreate.sh"
install -m 0755 "$SRC_DIR/postCreate.sh" "$FEATURE_DIR/postCreate.sh"
install -m 0755 "$SRC_DIR/postStart.sh"  "$FEATURE_DIR/postStart.sh"

# --- (6) Persistiere Options als Runtime-Config --------------------------
# Options sind nur waehrend install.sh als env vars verfuegbar; die
# Lifecycle-Hooks (onCreate/postCreate/postStart) sehen sie nicht. Im
# Feature-Manifest containerEnv wird ${templateOption:...} vom CLI NICHT
# substituiert (das ist Template-Syntax). Wir persistieren die Werte
# daher hier in einer Datei, die _lib.sh am Anfang sourcet.
CONFIG_ENV="${FEATURE_DIR}/config.env"
# Use ${VAR-default} (not ${VAR:-default}) so that an *explicit empty*
# user value — e.g. defaultMode="" — is preserved instead of being
# silently replaced by the install-time fallback.
{
    printf 'CLAUDE_TARGET_USER=%q\n'           "${TARGETUSER-}"
    printf 'CLAUDE_CHANNEL=%q\n'               "${CHANNEL-stable}"
    printf 'CLAUDE_DEFAULT_MODE=%q\n'          "${DEFAULTMODE-auto}"
    printf 'CLAUDE_REMOTE_CONTROL=%q\n'        "${REMOTECONTROL-true}"
    printf 'CLAUDE_REMOTE_CONTROL_SERVER=%q\n' "${REMOTECONTROLSERVER-false}"
    printf 'CLAUDE_MARKETPLACES=%q\n'          "${MARKETPLACES-}"
    printf 'CLAUDE_PLUGINS=%q\n'               "${PLUGINS-}"
} > "$CONFIG_ENV"
chmod 0644 "$CONFIG_ENV"

echo "==> claude-code ${version} cached + claude-code installed."
