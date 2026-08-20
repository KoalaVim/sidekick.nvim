## 1. Pane creation

- [x] 1.1 Parse the pane id from `herdr pane split` at `result.pane.pane_id`, falling back to unwrapped shapes, and report the raw output when it cannot be found
- [x] 1.2 Split from `$HERDR_PANE_ID` when it is set, so the pane is created next to Neovim rather than next to the focused pane

## 2. Launching the tool

- [x] 2.1 Replace `herdr agent start --kind` with `herdr pane run <pane_id> exec env <env> <cmd>`, built from `tool.cmd`
- [x] 2.2 Build the env from `NVIM`, the `sidekick-editor-proxy` as `EDITOR`/`VISUAL`, `tool.config.env` and `tool.env`, shell-quoting every value and unsetting `false` entries with `env -u`
- [x] 2.3 Close the pane and report when running the tool fails, so no empty pane is left behind
- [x] 2.4 Drop the kind guard from `start()`, keeping the kind map for `sessions()` discovery only

## 3. Pane placement

- [x] 3.1 Move the pane to its own tab for `create = "terminal"` and `create = "window"`, leaving it in place for `create = "split"`
- [x] 3.2 Restore focus to `$HERDR_TAB_ID` after a move, since `pane move --new-tab` focuses the tab it creates
- [x] 3.3 Keep returning `herdr agent attach <pane_id>` for `create = "terminal"`, and report the placement in the info message for external modes

## 4. Session state

- [x] 4.1 Base `is_running()` on `herdr pane get <pane_id>` instead of `herdr agent list`
- [x] 4.2 Read scrollback with `herdr pane read <pane_id> --source recent --lines <mux.dump> --ansi` and drop the now-unused `herdr_agent_target` field

## 5. Verification

- [x] 5.1 Verify all three `mux.create` modes against a live herdr: pane placement, external flag, attach command, and that focus stays on Neovim's tab
- [x] 5.2 Verify the pane closes and `is_running()` turns false when the tool exits
- [x] 5.3 Verify `EDITOR`, `NVIM` and tool env inside the pane, including a value containing a space, against a shell rc that exports its own `EDITOR`
- [x] 5.4 Verify a real agent is detected by herdr without `agent start`, is rediscovered by `sessions()`, and that `dump()` and `send()` work
- [x] 5.5 `stylua --check` the backend

## 6. Follow-ups

- [x] 6.1 Add `herdr` to the multiplexer list in `lua/sidekick/health.lua`, which still only checks `tmux` and `zellij`
