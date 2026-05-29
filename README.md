# Dev Container Features

This repository publishes a collection of [dev container Features](https://containers.dev/implementors/features/) to GHCR following the [Features distribution specification](https://containers.dev/implementors/features-distribution/).

## Features

### `claude-code`

A Claude Code installer plus host-credentials bridge for dev containers. The Feature pre-warms the Claude Code binary at image build time, runs `claude install` per target user on `onCreate`, forwards host OAuth credentials on `postCreate`, and patches workspace trust / settings on every `postStart`.

```jsonc
{
    "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
    "features": {
        "ghcr.io/kwitsch/devcontainer-features/claude-code:0": {
            "channel": "latest",
            "defaultMode": "auto",
            "remoteControl": true
        }
    }
}
```

Selected options (full list in [`src/claude-code/devcontainer-feature.json`](src/claude-code/devcontainer-feature.json)):

| Option | Default | Description |
|---|---|---|
| `targetUser` | `""` (auto-detect) | Container user that should own credentials and run `claude install`. Empty = first non-root login-capable user (lowest UID ≥ 1000). |
| `channel` | `""` (host wins) | `claude install <channel>` — `stable` or `latest`. Empty (default) reads the host's `~/.claude/settings.json` `autoUpdatesChannel` (written by `claude install` on the host); falls back to `latest` when the host setting is absent or the bind mount is unavailable (Codespaces prebuild). |
| `defaultMode` | `""` (host wins) | `permissions.defaultMode` in `~/.claude/settings.json`. Empty (default) leaves whatever the host wizard wrote untouched; set explicitly to override. `auto` also writes `skipAutoPermissionPrompt=true` to pre-accept the one-time opt-in dialog; `bypassPermissions` also writes `skipDangerousModePermissionPrompt=true`. |
| `remoteControl` | `true` | Sets `remoteControlAtStartup=true` in `~/.claude/settings.json` (where Claude Code ≥ 2.1.83 reads it) and `remoteDialogSeen=true` in `~/.claude.json` so every interactive `claude` session auto-registers for Remote Control without prompting. |
| `remoteControlServer` | `false` | Spawns `claude remote-control --spawn worktree` as a long-running daemon (workspace must be a git repo). |
| `marketplaces` | `""` | Comma-separated list passed to `claude plugin marketplace add <item>` (e.g. `anthropics/claude-code,my-org/internal`). |
| `plugins` | `""` | Comma-separated `<plugin>@<marketplace>` items passed to `claude plugin install`. |
| `forwardHostOnboarding` | `true` | Carry the host's first-run wizard state (`theme`, `tipsHistory`, `firstStartTime`, `editorMode`, …) into the container so `claude` skips the theme picker / onboarding on first invocation. |
| `theme` | `""` (host wins) | Theme written to `~/.claude.json`. Empty (default) preserves whatever `forwardHostOnboarding` copied from the host; set explicitly to force a theme. Final safety net forces `"dark"` if no value is set anywhere (host has no `.claude.json`, option not set), so the picker is guaranteed not to appear. |
| `claudeMd` | `""` | Literal markdown prepended to the container's `~/.claude/CLAUDE.md` (user-level memory). Empty (default) contributes nothing; combine with `hostClaudeMerge=true` to mirror the host CLAUDE.md verbatim, or set explicitly to add container-specific instructions. Re-applied on every `postStart` — container-side edits are overwritten when the computed body differs. |
| `hostClaudeMerge` | `true` | When the host's `~/.claude/CLAUDE.md` is readable via the bind mount, its content is appended after the `claudeMd` block (separated by a blank line). Silently skipped when the host file is absent. Set to `false` together with `claudeMd=""` to disable the helper entirely. |
| `useHostStatusbar` | `true` | Mirrors the host's `~/.claude/settings.json` `statusLine` into the container and symlinks any referenced `~/.claude/` script from the read-only host mount, so the status-line command runs unchanged. Strict mirror: `false` (or a host without `statusLine`) removes the key. Only `~/.claude/`-scoped scripts are linked. |

The Feature also declares `anthropic.claude-code` in `customizations.vscode.extensions`, so VS Code Remote / Codespaces / Cursor install the extension automatically on attach (no Feature option — declarative path via the IDE's own marketplace integration; non-VS-Code hosts ignore the hint).

> **Host requirement:** the Feature reads host OAuth tokens via bind mounts of `$HOME/.claude.json` and `$HOME/.claude/` (the lifecycle scripts only read from them — the Feature manifest cannot declare them `readonly` at the OS level, see [`NOTES.md`](src/claude-code/NOTES.md)). **macOS hosts are not supported** (Claude Code stores tokens in the Keychain, not on disk). On **Windows hosts**, open the project via VS Code's Remote-WSL extension (Claude Code lives inside the WSL distro, not under `%USERPROFILE%`) — see [`NOTES.md`](src/claude-code/NOTES.md#windows-hosts-use-remote-wsl). See [`NOTES.md`](src/claude-code/NOTES.md) for full platform compatibility and edge-case behavior.

## Repository structure

```
├── src
│   └── claude-code
│       ├── devcontainer-feature.json   # Manifest: options, mounts, lifecycle hooks
│       ├── install.sh                  # Build-time: cache binary, install tooling
│       ├── onCreate.sh                 # Per-user `claude install` (prebuild-cacheable)
│       ├── postCreate.sh               # Forward host credentials + plugin setup
│       ├── postStart.sh                # Token refresh + trust + optional daemon
│       ├── _lib.sh                     # Shared helpers (target-user detection, etc.)
│       └── NOTES.md                    # Merged into the generated README on release
└── test
    └── claude-code
        ├── scenarios.json              # Scenario configs (bypass, no-extras, …)
        ├── test.sh                     # Default (autogenerated) test
        └── <scenario>.sh               # One assertion script per scenarios.json key
```

## Testing locally

```bash
npm install -g @devcontainers/cli

# Autogenerated default test (defaults only):
devcontainer features test --skip-scenarios -f claude-code \
    -i mcr.microsoft.com/devcontainers/base:ubuntu .

# Scenario tests (from test/claude-code/scenarios.json):
devcontainer features test -f claude-code \
    --skip-autogenerated --skip-duplicated .
```

The CI matrix in [`.github/workflows/test.yaml`](.github/workflows/test.yaml) runs both modes against `mcr.microsoft.com/devcontainers/base:ubuntu` and `mcr.microsoft.com/devcontainers/base:debian` on every push/PR. Vanilla `debian`/`ubuntu` base images have no non-root user, which the target-user auto-detection requires, so they are intentionally not in the matrix.

## Releasing

Publishing is **manual**: trigger the [`Release dev container features & Generate Documentation`](.github/workflows/release.yaml) workflow (`workflow_dispatch`, `main` only). It does two things:

1. Publishes the Feature to GHCR at `ghcr.io/kwitsch/devcontainer-features/claude-code:<version>` (plus a `:latest` and majors), and a collection-level metadata package at `ghcr.io/kwitsch/devcontainer-features`.
2. Opens an automated PR with a regenerated `src/claude-code/README.md` (synthesized from the manifest + `NOTES.md`).

Bump `"version"` in `src/claude-code/devcontainer-feature.json` per [semver](https://containers.dev/implementors/features/#versioning) for every release.

### Prerequisites

- **Workflow permissions** — enable *Allow GitHub Actions to create and approve pull requests* in **Settings → Actions → General → Workflow permissions** so the documentation-update PR can be opened.
- **Package visibility** — GHCR packages publish as `private` by default. To stay on the free tier, flip the Feature's package to `public` after the first release at `https://github.com/users/kwitsch/packages/container/devcontainer-features%2Fclaude-code/settings`.

## License

[MIT](LICENSE)
