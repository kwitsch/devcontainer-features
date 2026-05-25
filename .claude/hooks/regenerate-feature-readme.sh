#!/usr/bin/env bash
# PostToolUse hook: after editing src/<feature>/devcontainer-feature.json
# or src/<feature>/NOTES.md, regenerate the Feature READMEs via
# `npx @devcontainers/cli` (same generator the release workflow uses via
# devcontainers/action@v1). Silent skip if npx is unavailable.
# If the generated src/<feature>/README.md actually changed, emits an
# additionalContext message so Claude reviews the top-level README too.
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

[ -d "src/$feature_name" ] || exit 0

# Silent skip when npx is not available (no Node toolchain on this host).
command -v npx >/dev/null 2>&1 || exit 0

namespace=""
if remote_url=$(git config --get remote.origin.url 2>/dev/null); then
  namespace=$(printf '%s' "$remote_url" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
fi
[ -n "$namespace" ] || exit 0

readme="src/$feature_name/README.md"
hash_before=""
[ -f "$readme" ] && hash_before=$(sha256sum "$readme" | awk '{print $1}')

echo "regenerate-feature-readme: regenerating Feature docs for '$feature_name' (namespace: $namespace) via npx" >&2
if ! npx --yes -p @devcontainers/cli devcontainer features generate-docs \
      --project-folder . --namespace "$namespace" >&2; then
  echo "regenerate-feature-readme: 'devcontainer features generate-docs' failed." >&2
  exit 1
fi

hash_after=""
[ -f "$readme" ] && hash_after=$(sha256sum "$readme" | awk '{print $1}')

if [ "$hash_before" != "$hash_after" ]; then
  jq -n --arg feat "$feature_name" --arg readme "$readme" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("Regenerated \($readme) from src/\($feat)/devcontainer-feature.json + NOTES.md. Review whether the top-level ./README.md (option tables, descriptions, usage snippets) also needs updating to stay in sync.")
    }
  }'
fi

exit 0
