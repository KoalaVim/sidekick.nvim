## 1. Bracketed paste delivery

- [x] 1.1 Wrap the herdr backend's `send()` payload in `ESC [ 200 ~` … `ESC [ 201 ~`, leaving the trailing newline inside the framing so it stays a soft newline rather than a submit
- [x] 1.2 Keep `submit()` as a separate `pane send-keys Enter`, so `send` without `submit` still leaves the input pending
- [x] 1.3 Keep the `herdr_embedded` early return in `send()` and `submit()` unchanged
- [x] 1.4 Add `-p` to the tmux backend's `paste-buffer` so it pastes rather than types

## 2. Focus on the backend contract

- [x] 2.1 Add `focus()` to the session base class in `session/init.lua` as a default no-op, so a backend that cannot focus needs no implementation
- [x] 2.2 Add a bounded request/response helper for herdr's socket API alongside the existing subscribe-only stream: connect, write one request, wait for the first response line, close
- [x] 2.3 Implement `focus()` on the herdr backend as `pane.focus { pane_id }` over the socket, returning early for an embedded session or one with no pane id
- [x] 2.4 Fall back to `herdr agent focus <herdr_pane_id>` with `notify = false` when there is no socket path, and keep every failure silent
- [x] 2.5 Leave the tmux and zellij backends without an implementation, so they inherit the no-op

## 3. Wiring focus through attach

- [x] 3.1 In `State.attach`, call `session:focus()` for a session with no terminal when `show` was requested and `focus ~= false`
- [x] 3.2 Place the call outside the just-attached gate, so a second `send` to an already attached session focuses as well
- [x] 3.3 Let `cli.show()`, `cli.toggle()` and `cli.focus()` reach a terminal-less session instead of returning early on `if not state.terminal`
- [x] 3.4 Confirm ordering: focus resolves before the scheduled `send`, so a tool that drops input while unfocused receives it focused

## 4. Verification against a live herdr

- [x] 4.1 `create = "split"`, claude in `Vim: Normal` with an empty composer: send a multi-line payload and confirm the full text arrives and the composer stays in normal mode
- [x] 4.2 Repeat 4.1 for codex with `[tui] vim_mode_default = true` and for cursor
- [x] 4.3 Confirm a single-line payload still renders inline rather than collapsing to a paste placeholder
- [x] 4.4 Confirm `send` moves focus to the agent's pane, and that `send({ focus = false })` does not
- [x] 4.5 Confirm `show`, `toggle` and `focus` reach a native herdr session
- [x] 4.6 Confirm the send that *creates* a native session focuses its pane, not just later sends
- [x] 4.7 Confirm `send` to a tool with no herdr kind mapping focuses its pane and raises no error toast
- [x] 4.8 Confirm an embedded session (`create = "terminal"`) is unaffected: the Neovim terminal is focused and no focus request is issued
- [x] 4.9 Confirm `submit` still submits, and that `send` without `submit` leaves the text pending and editable
- [x] 4.10 `stylua --check` and `selene` the touched files — stylua clean on all five; selene clean (0 errors, 0 warnings) on the four it can parse. `session/init.lua` fails to parse on the pre-existing `::continue::` at line 172, identically at HEAD without this change's one added line, because selene 0.31 exposes no luajit parser feature through `cargo install`

## 5. Record the pi defect

- [x] 5.1 Add a `DEFECTS.md` entry for the third-party `pi-vim` extension dropping a bracketed paste while in normal mode, with the measured evidence and the tools it was compared against, noting that `pi` without the extension is unaffected
- [ ] 5.2 File it upstream against `github.com/lajarre/pi-vim`, not against `pi` itself

## 6. Follow-ups

- [ ] 6.1 Give `cli.focus()` a working blur for a mux session, now that the socket helper exists — deciding what to focus instead of the agent is the open question, not the mechanism
- [ ] 6.2 Implement `focus()` for the tmux backend via `select-pane` / `select-window`, then reassess whether `mux_focus` is still needed anywhere
