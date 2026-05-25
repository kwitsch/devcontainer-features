> **⚠️ macOS hosts are not supported.** Claude Code on macOS stores OAuth tokens in the system Keychain, not in a file under `~/.claude/`. This Feature reads credentials via a read-only bind mount of `~/.claude/.credentials.json` — which simply does not exist on a macOS host. Use a Linux host, a Windows host with Claude Code installed natively, or WSL2 (with Claude Code installed inside the WSL distribution).

## Architecture

```
Image-Build (install.sh, as root):
    jq + curl + sudo installed
    Claude Code binary cached at /opt/claude-code/cache/claude  (SHA-256 verified)
    Lifecycle scripts installed to /usr/local/share/claude-code/

Container lifecycle:
    onCreate   ── `claude install <channel>` as target user
               ── → ~/.local/bin/claude  +  ~/.local/share/claude/versions/<v>/
               ── (prebuild-cacheable: result is baked into the prebuild image)

    postCreate ── credentials + minimal .claude.json from host bind mount
               ── marketplace add → plugin install (in that order)

    postStart  ── token refresh (if host has newer `expiresAt`)
               ── workspace trust + remoteControlAtStartup + permissions.defaultMode
               ── optional: spawn `claude remote-control --spawn worktree` daemon
```

## Host requirements

The Feature declares these bind mounts:

```
${localEnv:HOME}${localEnv:USERPROFILE}/.claude.json  →  /host_claude/.claude.json
${localEnv:HOME}${localEnv:USERPROFILE}/.claude       →  /host_claude/.claude
```

The `${localEnv:HOME}${localEnv:USERPROFILE}` concatenation resolves to the user's home on Linux/macOS (where only `HOME` is set) and on Windows (where only `USERPROFILE` is set), per [VS Code's recommended cross-platform mount pattern](https://code.visualstudio.com/remote/advancedcontainers/add-local-file-mount).

For the bind mounts to resolve, the host user must have **logged into Claude Code at least once** on the host machine, so that the source paths exist.

> **Mount mode is read-write at the OS level.** The `devContainerFeature.schema.json` for Feature manifests only accepts `{source, target, type}` Mount objects with `additionalProperties: false` — no `readonly` flag — so we cannot declare these mounts read-only from the Feature itself. The Feature's lifecycle scripts (`postCreate.sh`, `postStart.sh`) only ever *read* from `/host_claude/...`; they never write back. If you want a hard guarantee, override the mount in your own `devcontainer.json` with the docker-cli string form: `"source=...,target=/host_claude/...,type=bind,readonly"`.

### Platform-specific behavior

| Host | Where Claude Code stores credentials | Works? |
|---|---|---|
| Linux | `~/.claude.json` + `~/.claude/.credentials.json` | ✅ |
| Windows (native) | `%USERPROFILE%\.claude.json` + `%USERPROFILE%\.claude\` | ✅ |
| WSL2 with Claude Code installed *inside* WSL | `~/.claude.json` in the WSL distro | ✅ |
| WSL2 but Claude Code installed in *Windows* | `C:\Users\<you>\.claude.json` — **not** in WSL home | ❌ Requires symlinking `~/.claude.json` → `/mnt/c/Users/<you>/.claude.json` in WSL, or installing Claude Code inside WSL instead |
| macOS | OAuth tokens stored in **Keychain**, not in `~/.claude/` | ❌ Not supported by this Feature |
| VS Code "Clone in Container Volume" on Windows | Source paths might not exist on the host filesystem | ❌ See [devcontainers/spec#335](https://github.com/devcontainers/spec/issues/335) |

## How edge cases are handled

| Scenario | Behavior |
|---|---|
| No host credentials present | `postCreate` soft-fails (`exit 0`); the container is still usable, Claude prompts for login on first invocation. |
| Workspace is not a git repo | `remoteControlServer` is skipped with a warning (—`spawn worktree` requires git). |
| Target user differs between image build and runtime | Auto-detect runs on every lifecycle hook; no hardcoded UID. |
| Re-run on persistent volume | `claude install` skipped if `~/.local/bin/claude` already exists. Token refresh only writes when host `expiresAt` is strictly greater than container's. |
| Host account switched (different `userID`) | `postStart` merges the new account fields into the existing `.claude.json` without losing workspace trust + remote-control settings. |
| Concurrent reads during token refresh | All file writes use `mktemp` + atomic `mv` within the same filesystem. |

## Configuration option notes

**`defaultMode = "auto"`** — Anthropic's ML-classifier permission mode. Requires Claude Code ≥ 2.1.83 and a Pro/Max/Team/Enterprise account. The **first** cycle into auto mode per account may show a one-time opt-in confirmation; there is no known JSON field to pre-accept this. Use `"bypassPermissions"` instead if you need zero prompts unconditionally.

**`remoteControl`** vs. **`remoteControlServer`** — these are independent:
- `remoteControl=true` writes `remoteControlAtStartup=true` to `~/.claude.json` → every *interactive* `claude` session auto-registers for Remote Control.
- `remoteControlServer=true` spawns a long-running `claude remote-control --spawn worktree` *daemon* in `postStart` even when no user is at the terminal. PID + log at `~/.claude/remote-control.{pid,log}`.

**`marketplaces` / `plugins`** — comma-separated strings (devcontainer Feature options do not support native arrays). Items are trimmed of whitespace; empty items are skipped. Order is preserved. Both are only attempted if the credential setup did not soft-fail.

## Known upstream issues

- **`remoteControlServer` may fail on Claude Code 2.1.98** — the session-creation API rejects the v2.1.98 payload with HTTP 400 *"Extra inputs are not permitted"* ([anthropics/claude-code#45975](https://github.com/anthropics/claude-code/issues/45975)). The daemon spawns correctly, but the bridge to claude.ai fails. Awaiting Anthropic fix.
- **`claude install` location is hardcoded** to `~/.local/bin/claude` + `~/.local/share/claude/versions/<v>/` ([anthropics/claude-code#21019](https://github.com/anthropics/claude-code/issues/21019)). The Feature intentionally caches its build-time copy under `/opt/claude-code/cache/` to satisfy the "initial download during image build" requirement.

## Files installed at build time

| Path | Purpose |
|---|---|
| `/opt/claude-code/cache/claude` | Pre-warmed Claude Code binary (used by `onCreate`). |
| `/opt/claude-code/cache/VERSION` | Version marker for the cached binary. |
| `/usr/local/share/claude-code/_lib.sh` | Shared shell library (sourced by lifecycle scripts). |
| `/usr/local/share/claude-code/onCreate.sh` | Runs `claude install <channel>` as target user. |
| `/usr/local/share/claude-code/postCreate.sh` | Credential bootstrap + marketplaces + plugins. |
| `/usr/local/share/claude-code/postStart.sh` | Token refresh + trust + defaultMode + optional daemon. |
