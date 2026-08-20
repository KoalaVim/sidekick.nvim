## Why

When coding agents (Claude Code, Codex, Cursor, Pi, etc.) run inside Neovim's `:terminal` via sidekick.nvim, herdr cannot detect them — it sees Neovim as the pane's foreground process, not the nested agent. This makes sidekick-managed agents invisible to herdr's workspace, breaking agent status tracking, session discovery, and lifecycle management. Confirmed by testing: even agents with full lifecycle authority (Pi) are invisible when nested inside a Neovim terminal.

## What Changes

- Add a new **herdr mux backend** to sidekick.nvim's session system, alongside the existing tmux and zellij backends
- The backend runs agents in their own herdr panes using herdr's agent-aware API (`herdr agent start`, `herdr agent prompt`, `herdr agent attach`, etc.)
- Agents launched via sidekick become natively visible to herdr — detection works via foreground process inspection, no bridging or custom reporting needed
- Auto-detect herdr environment via `HERDR_ENV=1` and select the backend when running inside herdr
- Support three create modes: `"terminal"` (embedded in Neovim via `herdr agent attach`), `"split"` (herdr pane split), and `"window"` (herdr tab)
- Session persistence: herdr panes survive Neovim restarts; `herdr agent list` rediscovers sessions

## Capabilities

### New Capabilities
- `herdr-mux-backend`: The herdr mux backend implementation for sidekick.nvim — session lifecycle, pane management, agent communication via herdr CLI/socket API, and session discovery

### Modified Capabilities
- `ai-integration`: sidekick's mux backend selection gains herdr as an option; auto-detection logic updated to prefer herdr when `HERDR_ENV=1` is set

## Impact

- **New file**: `lua/sidekick/cli/session/herdr.lua` in the sidekick.nvim fork
- **Modified files**: `lua/sidekick/cli/session/init.lua` (backend registration), `lua/sidekick/config.lua` (config validation, auto-detection)
- **Dependencies**: herdr >= 0.8.0 (runtime, not build-time — backend only registers when `herdr` executable is found)
- **No breaking changes**: existing terminal/tmux/zellij backends are unaffected; herdr backend is opt-in via config or auto-detected
