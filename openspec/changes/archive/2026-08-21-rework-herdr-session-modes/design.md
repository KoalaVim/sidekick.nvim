## Context

The previous change made the herdr backend behave like the tmux backend. It cannot, and the reason is structural rather than a missing flag.

For `create = "terminal"`, tmux runs `tmux new -A -s <sid>` and zellij runs `zellij attach --create <sid>` with `ZELLIJ` unset. Both create a **separate mux session** that is invisible in the user's session and resizes to whatever client attaches. herdr has no equivalent: `herdr session list` shows one session per server socket, and a pane always lives in a rendered `workspace → tab → pane` tree. The straddle the backend adopted instead — a real pane, mirrored into Neovim via `agent attach` — is what produces the reported failures.

All herdr behaviour below was measured against a live herdr 0.8.2 server (socket schema version 1, protocol 20), not inferred.

**Detection is gated on the pane's tty foreground process group.**

```
nested:   fg_pgid == nvim's own pid
  ps:  53272  ttys012  Ss+  nvim         <- the pane's tty
       53371  ??       Ss   (term job)   <- nvim's OWN pty, invisible to herdr

control:  same agent as a child of sh on the pane's tty
          -> ADMITTED, agent_status: idle
```

Neovim gives its terminal child a different controlling tty, so herdr can never see it. This is a property of Neovim, not of any agent — confirmed non-detection for claude, pi, and codex. Admission is not argv0 matching: the control's foreground process reported its name as `2.1.237` (node self-rename) and was still admitted. Detection *content* is not the problem; running herdr's own detector offline against the nested pane's snapshot returns `state: idle` via rule `live_prompt_box`.

**`pane report-agent` admits any pane, subject to two gates.**

- *Gate A — source registration.* Same pane, back to back: `--source herdr:pi` REJECTED, `--source herdr:bogus` ADMITTED, `--source sidekick` ADMITTED. So herdr corroboration-gates its own registered integration sources and trusts any other source as an external lifecycle authority. The `--agent` label is irrelevant to admission and becomes the registry label verbatim.
- *Gate B — a prior `agent_session` claim locks the pane.* Once a pane carries one, `report_agent` is rejected from every source. Tried matching source, `seq: 999999999999999999`, matching `agent_session_id`, the CLI-hidden `pane.clear_agent_authority` (with and without `source`, with a high `seq`), and `release_agent` then `clear` then `report`. All returned `ok` and all left the claim standing.

Gate B is why the first nested attempt failed: claude's hook claims Neovim's pane at SessionStart, before sidekick can act. Which integration calls what differs per agent — claude, codex and cursor call `report_agent_session` only; pi additionally calls `report_agent` — but every one of them eventually claims, and pi's richer reporting is gated by Gate A anyway (nested pi ran a full turn and claimed nothing, while direct pi claimed at startup and reported `idle` → `done`).

**A dedicated herdr plugin cannot help with any of this.** The plugin docs are explicit: "There is no separate plugin SDK or restricted command set. The entire Herdr CLI is the plugin API," and "Runtime action registration and native non-terminal plugin UI are not part of plugin v1." Both gates and the tty rule are server-side and identical for a plugin. Nor is there a hidden placement: `overlay`, `split`, `tab` and `zoomed` "are normal Herdr panes after they open", and `popup` — the only genuinely invisible one — "has no pane ID … does not participate in pane, layout, persistence, or agent APIs", which disqualifies it as an agent host.

## Goals / Non-Goals

**Goals:**

- `create = "terminal"` starts reliably, is genuinely hidden, and is never cropped.
- An embedded session still appears in herdr's agent sidebar, pointing at the pane that actually hosts it.
- `split` and `window` keep herdr's native detection and gain real status.
- A rediscovered session can be attached rather than being forced external.

**Non-Goals:**

- Native herdr detection for an embedded session. Structurally impossible behind Neovim's PTY.
- Agent-session resume for embedded sessions. It comes from the integration hook that this design deliberately disables.
- More than one registered embedded session per Neovim instance. Neovim has one herdr pane.
- A companion herdr plugin. Captured as follow-on work below; it is a separate deliverable and must not block this fix.

## Decisions

**`create = "terminal"` creates no herdr pane.**
The tool runs in a Neovim terminal exactly as the `terminal` backend runs it, and sidekick registers the session on `$HERDR_PANE_ID` with `pane report-agent --source sidekick --agent <tool> --state <state>`. Verified end to end: the pane is admitted, `agent list` shows it, and focusing it in the sidebar lands on Neovim's pane — the correct destination, unlike a mirrored pane in a foreign tab. This deletes the attach race and the crop rather than working around them, because nothing attaches and nothing is resized.

*Alternative considered:* keep the pane and poll `agent get` before returning the attach command. Rejected: it fixes only the race. The visible tab and the crop are inherent to hosting the agent twice, and `agent attach`'s resize is permanent.

*Alternative considered:* a nested `herdr --session sidekick-<sid>`, the exact tmux/zellij analogue. Rejected: agents in another session are invisible to the user's sidebar, which removes the reason to have a herdr backend at all.

**Unset `HERDR_PANE_ID` for the embedded tool.**
Gate B is unrecoverable, so the claim must be prevented. Every integration begins `[ -n "${HERDR_PANE_ID:-}" ] || exit 0`, so clearing that one variable makes the hook a no-op while leaving `HERDR_ENV` and `HERDR_SOCKET_PATH` intact for anything else. The existing `env` mechanism already renders `false` entries as `env -u KEY`, so this is a per-tool env entry rather than new machinery. The cost is explicit: no agent-session id or transcript path, so herdr's `[session]` resume does not cover embedded sessions.

**Sidekick owns the embedded lifecycle.**
herdr does not drive status for a reported agent — a real prompt was sent to a nested agent and `agent_status` stayed `idle` for 12s while it worked, then flipped immediately when sidekick reported `working`. Sidekick has no status model today (`external_attached` and `external_started` are its only status icons), so this is net-new. The source must not be `herdr:*` or Gate A rejects it.

**`split` and `window` stay native, and gain pushed status.**
These modes already work: a real pane, herdr's own detection, no attach and so no race or crop. Two refinements. `pane move --new-tab --no-focus` replaces the manual `tab focus $HERDR_TAB_ID` compensation — pane ids are stable across a same-workspace tab move (verified: `previous_pane_id == pane_id`), so nothing needs re-reading. And `events.subscribe` delivers `PaneAgentStatusChangedEvent { pane_id, workspace_id, agent, agent_status: idle|working|blocked|done|unknown, display_agent, state_labels, title }`, which is a better status source than polling and shares its shape with the embedded path.

**Derive `mux_session` from tool and cwd in `sessions()`.**
`session/init.lua` stamps `started = true` before `M.new()`, so `init()` takes the `started` branch and computes `external = self.sid ~= self.mux_session`. With `mux_session = tool_name` that is always true. tmux stores the real session name, which equals `self.id` for an embedded session, so its identity check works; herdr needs the same property. Sidekick-started panes are additionally stamped with `pane report-metadata --token sidekick=<sid>`, which does round-trip (`"tokens":{"sidekick":"…"}` in `pane get`) and gives rediscovery a durable owner marker across Neovim restarts.

## Risks / Trade-offs

- **Embedded sessions lose native detection and resume.** Unavoidable, and now an explicit user-facing trade-off between the two modes rather than a silent straddle. `split`/`window` remain the full-fidelity choice.
- **Sidekick's status machine can drift from reality.** Mitigated by keeping reported state derived from signals sidekick already owns (job start/exit, send/submit) and treating `unknown` as the honest default rather than guessing.
- **Teardown must be reliable.** A stale registered agent outlives its session if Neovim crashes. `report-metadata` accepts `--ttl-ms`, and `release-agent` plus `--clear-display-agent` cover the ordinary path; the TTL is the crash backstop.
- **One embedded registration per Neovim.** A second embedded session in the same Neovim cannot also be registered. It still runs; it is simply not represented in herdr.
- **Behaviour depends on herdr internals that are not part of its documented contract** — specifically Gate A's treatment of unregistered sources. If herdr later gates all sources, embedded registration breaks and the mode degrades to a plain Neovim terminal. Worth a health check rather than a hard failure.

## Follow-on work: companion herdr plugin

Not part of this change. The one capability sidekick cannot reach from its own process is navigation *back* into the right Neovim session: focusing a registered agent in herdr's sidebar lands on Neovim's pane, but Neovim does not learn which session was wanted. A `sidekick-herdr` plugin solves it, because `[[actions]]` receive `HERDR_PLUGIN_CONTEXT_JSON`, which "can include workspace, tab, focused pane, worktree, agent, selected text, clicked URL" — enough to RPC into Neovim via `$NVIM` and open that exact session. `KoalaVim/herdr-nvim-aware` is prior art for the same pattern. A plugin is also the natural home for an `agent.view.set` view filtered on the `sidekick` token (its `[[startup]]` hook is how the docs suggest re-applying such a view after a restart or live handoff) and a distribution vehicle via `herdr plugin install`.

## Migration Plan

No config changes. `cli.mux.create` keeps its three values and its documented meaning; only what `terminal` does under herdr changes. Users who want herdr's native detection and resume should choose `split` or `window`, and the docs for `create` should say so for the herdr backend.
