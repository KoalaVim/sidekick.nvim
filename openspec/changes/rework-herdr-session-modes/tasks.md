## 1. Embedded mode (`create = "terminal"`)

- [ ] 1.1 Stop splitting a herdr pane for `create = "terminal"`: run the tool in a Neovim terminal the way the `terminal` backend does, and return no attach command
- [ ] 1.2 Unset `HERDR_PANE_ID` for the embedded tool so its integration hook cannot claim Neovim's pane, leaving `HERDR_ENV` and `HERDR_SOCKET_PATH` intact
- [ ] 1.3 Register the session on `$HERDR_PANE_ID` with `herdr pane report-agent --source sidekick --agent <tool> --state <state>` once the terminal job is running
- [ ] 1.4 Refuse to register a second embedded session on the same Neovim pane, and log why rather than overwriting the first
- [ ] 1.5 Set `display_agent` and a `title` via `herdr pane report-metadata` so the sidebar labels Neovim's pane, with `--ttl-ms` as a crash backstop
- [ ] 1.6 Tear down on session close: `release-agent`, `--clear-display-agent`, and clear the token

## 2. Embedded lifecycle state

- [ ] 2.1 Add a status field (`idle` / `working` / `blocked` / `unknown`) to the session state, defaulting to `unknown`
- [ ] 2.2 Drive it from signals sidekick already owns — job start, `send`/`submit`, job exit — without guessing from terminal content
- [ ] 2.3 Report every transition with `pane report-agent`, keeping the source non-`herdr:*` so Gate A admits it

## 3. Native modes (`split`, `window`)

- [ ] 3.1 Pass `--no-focus` to `herdr pane move --new-tab` and drop the `tab focus $HERDR_TAB_ID` compensation
- [ ] 3.2 Stamp sidekick-started panes with `herdr pane report-metadata --token sidekick=<sid>`
- [ ] 3.3 Leave native detection alone — no `report-agent` for these modes, so herdr keeps lifecycle authority

## 4. Session discovery

- [ ] 4.1 Derive `mux_session` in `sessions()` from the tool and the agent's cwd so `sid == mux_session` holds for sidekick-owned sessions, instead of using the bare tool name
- [ ] 4.2 Prefer the `sidekick` pane token over the cwd heuristic when present, so ownership survives a Neovim restart
- [ ] 4.3 Verify `attach()` now returns a `Cmd` for a rediscovered native session, and that a user's hand-started agent is still reported external

## 5. Status events

- [ ] 5.1 Subscribe to `pane.agent_status_changed` over the socket and map `PaneAgentStatusChangedEvent` onto the session status field
- [ ] 5.2 Fall back cleanly when the subscription is unavailable, rather than failing the backend

## 6. Verification against a live herdr

- [ ] 6.1 `create = "terminal"`: session starts with no `agent_not_found`, no new tab appears, no pane is resized, and `herdr agent list` shows the session on Neovim's pane
- [ ] 6.2 Confirm the integration hook did not claim the pane (`pane get` shows no `agent_session`) and that `report-agent` was admitted
- [ ] 6.3 `split` and `window`: pane placement, external flag, focus stays on Neovim's tab, and native detection still reports status
- [ ] 6.4 Restart Neovim with a native session running and confirm it is rediscovered and attachable
- [ ] 6.5 Kill Neovim without teardown and confirm the registered agent expires via `--ttl-ms` rather than lingering
- [ ] 6.6 Repeat 6.1–6.2 for `pi` and `codex`, whose integrations claim at different times than `claude`
- [ ] 6.7 `stylua --check` the backend

## 7. Health and docs

- [ ] 7.1 Add a health check that embedded registration works (report and read back on Neovim's pane), so a future herdr that gates all sources degrades visibly rather than silently
- [ ] 7.2 Document, for the herdr backend, that `split`/`window` keep native detection and resume while `terminal` trades them for a hidden, uncropped session

## 8. Follow-ups

- [ ] 8.1 Companion `sidekick-herdr` plugin for sidebar-to-session navigation and an `agent.view.set` view on the `sidekick` token — separate deliverable, does not block this change
