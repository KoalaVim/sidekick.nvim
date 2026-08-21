## 1. Embedded mode (`create = "terminal"`)

- [x] 1.1 Stop splitting a herdr pane for `create = "terminal"`: run the tool in a Neovim terminal the way the `terminal` backend does, and return no attach command
- [x] 1.2 Unset `HERDR_PANE_ID` for the embedded tool so its integration hook cannot claim Neovim's pane, leaving `HERDR_ENV` and `HERDR_SOCKET_PATH` intact
- [x] 1.3 Register the session on `$HERDR_PANE_ID` with `herdr pane report-agent --source sidekick --agent <tool> --state <state>` once the terminal job is running
- [x] 1.4 Refuse to register a second embedded session on the same Neovim pane, and log why rather than overwriting the first
- [x] 1.5 Set `display_agent` and a `title` via `herdr pane report-metadata` so the sidebar labels Neovim's pane, with `--ttl-ms` as a crash backstop
- [x] 1.6 Tear down on session close: `release-agent`, `--clear-display-agent`, and clear the token

## 2. Embedded lifecycle state

- [x] 2.1 Add a status field (`idle` / `working` / `blocked` / `unknown`) to the session state, defaulting to `unknown`
- [x] 2.2 Drive it from signals sidekick already owns — job start, `send`/`submit`, job exit — without guessing from terminal content
- [x] 2.3 Report every transition with `pane report-agent`, keeping the source non-`herdr:*` so Gate A admits it

## 3. Native modes (`split`, `window`)

- [x] 3.1 Pass `--no-focus` to `herdr pane move --new-tab` and drop the `tab focus $HERDR_TAB_ID` compensation
- [x] 3.2 Stamp sidekick-started panes with `herdr pane report-metadata --token sidekick=<sid>`
- [x] 3.3 Leave native detection alone — no `report-agent` for these modes, so herdr keeps lifecycle authority

## 4. Session discovery

- [x] 4.1 Give `mux_session` a per-pane identity in `sessions()` instead of the bare tool name, which is the same for every pane running that tool
- [x] 4.2 Report the `sidekick` pane token as ownership information, so ownership survives a Neovim restart
- [x] 4.3 Verify a rediscovered native session is external — `attach()` returns no `Cmd`, no Neovim terminal opens, no pane is resized — and that a user's hand-started agent is external too

## 5. Status events

- [x] 5.1 Subscribe to `pane.agent_status_changed` over the socket and map `PaneAgentStatusChangedEvent` onto the session status field
- [x] 5.2 Fall back cleanly when the subscription is unavailable, rather than failing the backend

## 6. Verification against a live herdr

- [x] 6.1 `create = "terminal"`: session starts with no `agent_not_found`, no new tab appears, no pane is resized, and `herdr agent list` shows the session on Neovim's pane
- [x] 6.2 Confirm the integration hook did not claim the pane (`pane get` shows no `agent_session`) and that `report-agent` was admitted
- [x] 6.3 `split` and `window`: pane placement, external flag, focus stays on Neovim's tab, and native detection still reports status
- [x] 6.4 Restart Neovim with a native session running and confirm it is rediscovered and attachable
- [x] 6.5 Kill Neovim without teardown and confirm the registered agent expires via `--ttl-ms` rather than lingering
- [x] 6.6 Repeat 6.1–6.2 for `pi` and `codex`, whose integrations claim at different times than `claude`
- [x] 6.7 `stylua --check` the backend

## 7. Health and docs

- [x] 7.1 Add a health check that embedded registration works (report and read back on Neovim's pane), so a future herdr that gates all sources degrades visibly rather than silently
- [x] 7.2 Document, for the herdr backend, that `split`/`window` keep native detection and resume while `terminal` trades them for a hidden, uncropped session

## 8. Follow-ups

- [ ] 8.1 Companion `sidekick-herdr` plugin for sidebar-to-session navigation and an `agent.view.set` view on the `sidekick` token — separate deliverable, does not block this change
