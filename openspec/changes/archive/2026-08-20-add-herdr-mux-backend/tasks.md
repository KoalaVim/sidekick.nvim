## 1. Config and Registration

- [x] 1.1 Add `"herdr"` to `mux.backend` type annotation and validation in `lua/sidekick/config.lua`
- [x] 1.2 Update mux backend auto-detection: `HERDR_ENV` → herdr, `ZELLIJ` → zellij, default → tmux
- [x] 1.3 Register herdr backend in `lua/sidekick/cli/session/init.lua` — require `sidekick.cli.session.herdr` when `herdr` is executable and `HERDR_ENV=1`

## 2. Backend Core — `lua/sidekick/cli/session/herdr.lua`

- [x] 2.1 Create `herdr.lua` with class definition, fields (`herdr_pane_id`, `herdr_agent_target`), and tool-to-kind mapping table
- [x] 2.2 Implement `init()` — set `external` based on `HERDR_ENV` and `mux.create`, set `priority` (10 external / 50 embedded), store `mux_session`
- [x] 2.3 Implement `start()` — shell out to `herdr pane split` (parse JSON response for `pane_id`), then `herdr agent start <name> --kind <kind> --pane <id>`. Return `Cmd` with `herdr agent attach <pane_id>` for embedded mode, `nil` for split mode
- [x] 2.4 Implement `send(text)` — `herdr pane send-text <pane_id> <text>`
- [x] 2.5 Implement `submit()` — `herdr pane send-keys <pane_id> Enter`
- [x] 2.6 Implement `attach()` — return `Cmd` with `herdr agent attach <pane_id>` when `mux_session` matches
- [x] 2.7 Implement `detach()` — no-op (herdr pane persists)
- [x] 2.8 Implement `is_running()` — query `herdr agent list`, check if pane_id still present
- [x] 2.9 Implement `dump()` — `herdr agent read <target> --source recent --ansi`, return raw output

## 3. Session Discovery

- [x] 3.1 Implement `sessions()` — parse `herdr agent list` JSON output, match agent kinds against sidekick tool configs, return session states with tool, cwd, pane_id, and pids
- [x] 3.2 Handle the tool name → herdr kind mapping for discovery (match `agent` field from herdr to sidekick tool names)

## 4. Testing and Validation

- [ ] 4.1 Manual test: start claude via sidekick with herdr backend in embedded mode — verify herdr detects agent, verify sidekick can send/receive
- [ ] 4.2 Manual test: start agent in split mode — verify herdr pane appears alongside Neovim, agent detected
- [ ] 4.3 Manual test: restart Neovim — verify `sessions()` rediscovers the running agent and reattach works
- [ ] 4.4 Manual test: close herdr pane externally — verify `is_running()` returns false and sidekick prunes session
