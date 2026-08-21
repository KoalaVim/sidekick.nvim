## Why

Two defects with one root cause: sidekick's mux backends are one-way text pipes. They push bytes at a pane but cannot move the user to it, and they deliver prompt text as raw keystrokes rather than as a paste.

**Raw keystrokes are parsed as vim commands.** Measured against a live herdr 0.8.2 (socket schema version 1, protocol 20) by sending `line one\nline two\nline three` into an empty composer sitting in vim normal mode:

| tool | vim mode source | raw `pane send-text` | bracketed paste |
| --- | --- | --- | --- |
| claude | `~/.claude/settings.json` `editorMode: vim` | broken | full text delivered |
| cursor | on | **nothing arrives at all** | full text delivered |
| codex | `~/.codex/config.toml` `[tui] vim_mode_default` | `ne one` — `l` and `i` consumed, flips to `Vim: Insert` | full text, stays `Vim: Normal` |
| pi | `pi-vim` extension | `ne one`, flips to Insert | **silently dropped** |

`l` moves the cursor, `i` enters insert, and the remainder of the payload is inserted. Every tool with a modal composer is affected. codex and pi only appeared healthy because they lose exactly two characters and land in insert mode, which reads as success. The tmux backend has the same defect: `paste-buffer -d -r` omits `-p`, so it types rather than pastes.

`herdr pane send-text` passes ESC bytes through untouched — `A\e[200~B\e[201~C` arrives byte-for-byte at the pane tty — so the backend can frame the payload itself. `herdr agent prompt` already honors the pane's live paste mode, but it always sends Enter afterwards, so it cannot serve a `send` without `submit`.

**Focus never reaches a mux pane.** `State.attach` shows and focuses through `state.terminal`, which `state.lua:60` populates only when `session.backend == "terminal"`. A native herdr session has a pane and no terminal, so it falls into the `elseif attached` branch — one notification, then nothing. `cli.show()`, `cli.toggle()` and `cli.focus()` all return early on `if not state.terminal`, so sidekick's entire window-management surface is dead for a session running in a mux pane, not just the focus half of `send`. Focus is a `Terminal` method and not a `Session` method. tmux has the same gap: it never calls `select-pane`.

## What Changes

- The herdr backend's `send()` SHALL wrap its payload in bracketed paste (`ESC [ 200 ~` … `ESC [ 201 ~`), unconditionally and for every tool. Three of the four tools measured honor it correctly, and codex demonstrates the intended semantics by leaving the composer in `Vim: Normal` after the paste.
- The tmux backend's `send()` gains `paste-buffer -p` for the same reason.
- `focus()` joins the mux backend contract as an optional hook that defaults to a no-op. The herdr backend implements it with `pane.focus` over herdr's socket API, falling back to `herdr agent focus <pane_id>` when there is no socket to talk to. The socket call is required rather than preferred: `agent focus` resolves against herdr's agent registry, which lags a freshly started tool by ~600ms (measured), so the send that creates the session would never focus.
- `State.attach` calls `session:focus()` for a session with no terminal of its own when `show` was requested and focus was not declined, so `send`, `show`, `toggle` and `focus` all reach a mux pane. The call sits outside the just-attached gate, because a second `send` to an already attached session must focus too.
- The normal-mode bracketed-paste drop is recorded in `DEFECTS.md` as an upstream defect in the third-party `pi-vim` extension (`github.com/lajarre/pi-vim`), not worked around here. `pi` itself is not at fault: the drop only appears with that extension loaded.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `herdr-mux-backend`: how `send()` frames its payload, and a new requirement for focusing the agent's pane.
- `mux-session-backends`: `focus()` added to the backend contract, and tmux input delivery framed as a paste.
- `cli-session-management`: `State.attach` focuses a session that has no Neovim terminal.

## Impact

- `lua/sidekick/cli/session/herdr.lua` — `send()` framing, new `focus()`, and a request/response helper for herdr's socket API alongside the existing subscribe-only stream.
- `lua/sidekick/cli/session/tmux.lua` — `paste-buffer -p`.
- `lua/sidekick/cli/session/init.lua` — `focus()` on the backend base class.
- `lua/sidekick/cli/state.lua` — `M.attach` focus path for terminal-less sessions.
- `lua/sidekick/cli/init.lua` — `toggle()` and `focus()` currently return early without a terminal.
- `openspec/DEFECTS.md` — the pi upstream defect.
- Behavior change for users on `cli.mux.create = "split"` or `"window"`: sending now moves keyboard focus to the agent's pane, matching what `create = "terminal"` already does with the Neovim terminal. `focus = false` opts out per call.
- Users of `pi` who send from normal mode change failure mode: today two characters are eaten and the rest is inserted, afterwards nothing is delivered. Neither is correct; the second is non-destructive and recoverable by entering insert mode and resending.
- claude renders a framed payload of three or more lines as a `[Pasted text #N +N lines]` placeholder rather than inline; one and two line payloads are unchanged, and codex renders three lines inline. The full content is still delivered and the placeholder expands, but this is a visible change for the multi-line context sidekick sends most.
- Requires a herdr build with `pane.focus` on the socket API and ESC passthrough on `pane send-text` (verified against herdr 0.8.2, socket schema version 1, protocol 20).
