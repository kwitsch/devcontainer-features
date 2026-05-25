#!/usr/bin/env bash
# PostToolUse hook: after editing src/<feature>/devcontainer-feature.json
# or src/<feature>/NOTES.md, regenerate the Feature READMEs with the
# devcontainer CLI (same generator the release workflow uses via
# devcontainers/action@v1).
set -euo pipefail

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""')
case "$tool_name" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
[ -z "$file_path" ] && exit 0

if [[ ! "$file_path" =~ (^|/)src/([^/]+)/(devcontainer-feature\.json|NOTES\.md)$ ]]; then
  exit 0
fi
feature_name="${BASH_REMATCH[2]}"

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] && cd "$cwd"

if [ ! -d "src/$feature_name" ]; then
  echo "regenerate-feature-readme: src/$feature_name not found in $(pwd); skipping." >&2
  exit 0
fi

if ! command -v devcontainer >/dev/null 2>&1; then
  echo "regenerate-feature-readme: devcontainer CLI not found; install with 'npm install -g @devcontainers/cli'. Skipping regeneration for $feature_name." >&2
  exit 0
fi

namespace=""
if remote_url=$(git config --get remote.origin.url 2>/dev/null); then
  namespace=$(printf '%s' "$remote_url" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
fi
if [ -z "$namespace" ]; then
  echo "regenerate-feature-readme: could not derive namespace from git remote.origin.url; skipping." >&2
  exit 0
fi

echo "regenerate-feature-readme: regenerating Feature docs for '$feature_name' (namespace: $namespace)" >&2
if ! devcontainer features generate-docs --project-folder . --namespace "$namespace" >&2; then
  echo "regenerate-feature-readme: 'devcontainer features generate-docs' failed." >&2
  exit 1
fi

exit 0
