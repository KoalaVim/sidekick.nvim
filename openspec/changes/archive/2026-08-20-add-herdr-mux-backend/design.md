## Context

sidekick.nvim's mux backend system is a strategy pattern that abstracts terminal multiplexers. Today it supports three mux backends (tmux, zellij, opencode) plus the built-in terminal backend. Each backend implements a contract (`start`, `send`, `submit`, `attach`, `detach`, `sessions`, `is_running`, `dump`) and is registered in `session/init.lua` if its executable is found.

herdr is a terminal workspace manager for AI coding agents. It manages panes, detects agents via foreground process inspection and screen manifest rules, and exposes a rich agent-aware API (`herdr agent start/prompt/attach/read/list/wait`). When agents run inside Neovim's `:terminal` via sidekick's terminal backend, herdr sees Neovim as the foreground process — the nested agent is invisible. This is confirmed by testing: even Pi (which has full herdr lifecycle authority) is undetectable when nested.

The tmux backend is the closest analogue — it supports embedded mode (agent inside Neovim terminal via `tmux attach-session`), external window/split modes, session persistence, and scrollback capture. The herdr backend follows the same patterns.

## Goals / Non-Goals

**Goals:**
- Agents launched via sidekick are natively visible to herdr (idle/working/blocked status, session identity)
- Session persistence: herdr panes survive Neovim restarts, rediscoverable via `herdr agent list`
- Three create modes: `terminal` (embedded via `herdr agent attach`), `split` (herdr pane split), `window` (herdr tab — future, not in initial implementation)
- Auto-detect herdr environment and select backend when `HERDR_ENV=1`
- Consistent with existing backend architecture — follow tmux backend patterns

**Non-Goals:**
- Replacing herdr's native agent detection with custom `report-agent` calls (the whole point is native detection)
- Supporting `window` create mode in the initial implementation (split and terminal are sufficient; tab API can be added later)
- Making herdr a hard dependency — backend only registers when `herdr` executable is found
- Modifying KoalaVim's ai.lua or general.lua — this change is entirely within sidekick.nvim

## Decisions

### 1. Two-step pane creation: `pane split` + `agent start`

`herdr pane split` creates a shell pane but doesn't accept a command. `herdr agent start <name> --kind <kind> --pane <id>` starts an agent in an existing pane and waits for readiness detection.

**Why this over alternatives:**
- `herdr pane run` just sends text + Enter to an existing pane — it doesn't manage agent lifecycle
- The two-step approach gives us the pane ID from split, then `agent start` confirms the agent is ready before sidekick proceeds
- `agent start` has a built-in readiness timeout (default 30s) — no need for custom polling

### 2. Use `herdr agent prompt` for send, not `herdr pane send-text`

`herdr agent prompt <target> <text>` is semantically aware — it submits a prompt to the agent and optionally waits for state transition (`--wait`).

**Why this over `pane send-text`:**
- `pane send-text` is raw text injection with no awareness of agent state
- `agent prompt` handles the submission correctly for each agent type
- `--wait` enables reliable synchronous prompt submission without polling or prompt-pattern scraping
- Consistent with herdr's design philosophy of agent-aware operations

**Trade-off:** `agent prompt` combines send + submit. sidekick's contract separates `send(text)` and `submit()`. The backend maps `send()` to `herdr pane send-text` (raw text, no Enter) and `submit()` to `herdr pane send-keys Enter`. The combined `agent prompt` is available for higher-level flows but isn't required by the contract.

### 3. Embedded mode via `herdr agent attach`

For `create = "terminal"` mode, the backend returns a `Cmd` with `herdr agent attach <pane_id>`. This attaches to the agent's terminal PTY, which sidekick then hosts in a Neovim `:terminal` buffer — the same pattern as tmux's `tmux attach-session -t <id>`.

**Why this works:**
- `herdr agent attach` connects directly to the agent's terminal
- The agent runs in its own herdr pane (natively detected), while the user sees it embedded in Neovim
- Detaching (closing the Neovim terminal buffer) doesn't kill the agent — the herdr pane persists

### 4. Session discovery via `herdr agent list`

`herdr agent list` returns all detected agents with their pane IDs, status, session info, and cwd. This maps to the `sessions()` backend method.

**Why this over `herdr pane list` + process walking:**
- `agent list` already does the detection work — no need to replicate herdr's process tree walking in Lua
- Returns agent-specific metadata (status, session, kind) that raw pane listing doesn't
- Simpler implementation than tmux backend's manual pane enumeration + process tree traversal

**Filtering:** `sessions()` filters `agent list` results by matching against sidekick's configured tools. The herdr agent kind is matched to sidekick tool names via a mapping table.

### 5. Auto-detect herdr for backend selection

Config auto-detection chain: `HERDR_ENV=1` → herdr backend; `ZELLIJ` → zellij backend; default → tmux. This goes in `config.lua`'s mux defaults.

**Why auto-detect:**
- Users running inside herdr expect it to work without manual config
- Consistent with how zellij is auto-detected via `$ZELLIJ`
- Can be overridden by explicit `mux.backend = "tmux"` config

### 6. Priority: 10 (external) / 50 (embedded)

Same as tmux backend. In embedded mode (terminal create), priority 50 ensures the terminal backend (100) takes precedence for the wrapper. In external mode (split), priority 10 is lowest, appropriate for externally-managed sessions.

### 7. Tool name to herdr kind mapping

herdr's `agent start --kind` uses specific labels (claude, codex, cursor, pi, gemini, etc.). sidekick tool names mostly match, but the mapping is maintained as a lookup table in the backend to handle any divergences.

herdr's known kinds (from `agent start --help`): pi, claude, codex, gemini, cursor, devin, agy, cline, omp, mastracode, opencode, copilot, kimi, kiro, droid, amp, grok, hermes, kilo, qodercli, maki.

### 8. Scrollback via `herdr agent read`

`herdr agent read <target> --source recent --ansi` provides terminal output with ANSI escape codes, mapping to the `dump()` method. Unlike zellij (whose `dump-screen` lacks ANSI), herdr's read supports full ANSI output.

## Risks / Trade-offs

**[herdr CLI overhead]** → Each operation shells out to `herdr` CLI or writes to the socket. The socket path is available via `HERDR_SOCKET_PATH` — for performance-sensitive operations (send, read), the backend could use `vim.uv` to write directly to the Unix socket instead of spawning a process. Initial implementation uses CLI for simplicity; socket optimization is a follow-up if needed.

**[Agent start latency]** → `herdr agent start` has a readiness wait (up to 30s) which blocks the start flow. This is acceptable because it ensures the agent is actually ready before sidekick tries to interact with it. The `--timeout` flag can tune this.

**[herdr version coupling]** → The backend depends on herdr's CLI interface. If herdr changes its API, the backend breaks. Mitigation: herdr is versioned (currently 0.8.0), and the backend could check `herdr --version` during registration to ensure compatibility.

**[External mode pane lifecycle]** → In split mode, herdr manages the pane. If the user manually closes the herdr pane, sidekick's session state becomes stale. The `is_running()` check via `herdr agent list` handles this — a closed pane means the agent disappears from the list.

**[`--takeover` for embedded attach]** → `herdr agent attach` has a `--takeover` flag. Need to determine if this is required when multiple Neovim instances try to attach to the same agent. Initial implementation omits it; add if concurrent attach fails.
