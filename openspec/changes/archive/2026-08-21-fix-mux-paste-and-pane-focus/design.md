## Context

Both defects live at the boundary where sidekick stops owning the surface. When a tool runs in a Neovim terminal, sidekick owns the window and the input: `Terminal:focus()` moves the cursor and `Terminal:send()` writes to a job it spawned. When the tool runs in a mux pane, sidekick owns neither. It has a pane id and a CLI, and the two things it does with them — write text, send Enter — are the two crudest operations available.

All herdr behavior below was measured against a live herdr 0.8.2 server (socket schema version 1, protocol 20), not inferred.

**Raw text delivery is keystroke delivery.** `herdr pane send-text <pane> <text>` writes the bytes to the pane tty with no framing. An application with a modal composer therefore runs the payload through its mode machine. With the composer empty and in normal mode, the first two bytes of `line one…` are `l` (move right, a no-op on an empty line) and `i` (enter insert); everything after is inserted. Measured, per tool:

```
codex   [tui] vim_mode_default = true
  before   › Ask Codex to do anything                Vim: Normal
  raw   →  › ne one / line two / line three          Vim: Insert    <- 2 chars lost
  paste →  › line one / line two / line three        Vim: Normal    <- correct

pi      pi-vim extension
  raw   →  composer: "ne one / line two / line three"   Vim: Insert
  paste →  composer: EMPTY                              Vim: Normal  <- dropped

cursor
  raw   →  composer: EMPTY (nothing arrived)
  paste →  composer: "line one / line two / line three"
```

claude was confirmed by the reporter: raw fails in normal mode, bracketed paste works. Both pi cells work when the composer is already in insert mode, which is why `pi` reads as healthy in daily use — pi returns to insert after each turn, so normal mode is rare there, while claude is habitually left in normal mode.

**The transport can frame.** `pane send-text` does not sanitize control bytes. Sending `A\e[200~B\e[201~C` into `cat -v` produced `A^[[200~B^[[201~C`, so a real `0x1B` reached the tty in both positions.

**The agent surface already solves this, at a price.** `herdr agent prompt` "honors the pane's live bracketed-paste mode and sends text followed by encoded Enter after a short delay". It always submits, and it rejects a blocked agent with `agent_blocked`. `send` without `submit` is sidekick's default, so this cannot be the delivery path.

**Focus has no plumbing at all.** `State.attach` (`state.lua:172`) reads `state.terminal`, which the metatable in `get_state` resolves to `Terminal.get(session.id)` only when `session.backend == "terminal"`. A native herdr session's backend is `herdr`, so `state.terminal` is `nil` and the whole show/focus block is skipped. `session/init.lua` defines `send`, `submit`, `attach`, `detach`, `start`, `is_running`, `set_status` and `sessions` — no `focus`.

**Focus primitives.** `herdr agent focus <target>` accepts a unique live agent name or the pane id hosting that agent; targeting a non-agent pane returns `agent_not_found` (verified). The socket API also exposes `pane.focus { pane_id }`, which has no CLI verb. `herdr pane focus --direction` focuses a *neighbor*, not a named pane.

## Goals / Non-Goals

**Goals:**

- Prompt text arrives intact in a modal composer regardless of the composer's current mode.
- Sending to a session in a mux pane moves the user to that pane, as it already does for a session in a Neovim terminal.
- One mechanism per defect, shared across backends rather than special-cased per tool.

**Non-Goals:**

- Working around `pi`'s normal-mode paste drop. It is an upstream defect and is recorded as one.
- A `hide` or `blur` counterpart for a mux pane. There is no herdr analogue of hiding a pane. Blur is one `pane.focus` call away once this lands, but deciding what to focus instead of the agent is a separate question.
- Reading the pane's live bracketed-paste state. herdr does not expose it on `PaneInfo`; only `agent prompt` consults it internally.

## Decisions

**Wrap every payload in bracketed paste, unconditionally.**
`send()` emits `ESC [ 200 ~` + text + `ESC [ 201 ~`. A bracketed paste is a text-insertion event by definition, so consuming it through a vim state machine is the application's defect, not the sender's. Three of the four tools measured implement it correctly and codex proves the intended semantics by preserving `Vim: Normal` across the paste. Rendering is unaffected for codex, which renders the raw and the framed three-line payload identically inline. It is not unaffected for claude, which collapses a framed payload of three or more lines to a `[Pasted text #N +N lines]` placeholder; one and two line payloads still render inline. That is a real cost, and it is accepted below.

*Alternative considered:* a per-tool opt-in flag mirroring `mux_focus`. Rejected. Every tool measured is broken on raw delivery, so the flag would have to be set on all of them, and its only remaining function would be to preserve pi's mangled-but-visible failure. Two characters silently eaten and then submitted is worse than nothing arriving.

*Alternative considered:* normalize the composer with `esc` then `i` before sending, which is verified working for pi in both modes. Rejected on two counts. `esc` interrupts a running turn in claude, and sidekick's `send` is explicitly usable while an agent is working, so this would kill in-flight work. It also requires sidekick to mirror each tool's vim setting, which it cannot observe, and a wrong mirror is destructive — `esc` clears the composer and `i` inserts a literal `i`.

*Alternative considered:* deliver through `herdr agent prompt`, which frames correctly for free. Rejected: it always submits, so `send` without `submit` would become impossible, and it refuses a blocked agent.

**`focus()` on the backend contract, not in `M.send`.**
`send` is one of four callers that want the agent's surface in front of the user; `show`, `toggle` and `focus` are the others, and all four are equally broken for a mux pane. Adding `focus()` to the base class in `session/init.lua` as a default no-op and calling it from `State.attach` fixes them together. Special-casing herdr inside `M.send` would fix one of four and leave the abstraction inverted, with window management living on `Terminal` while the session that owns the window lives elsewhere.

**Focus by default, opting out with `focus = false`.**
This is what the terminal path already does: `opts.focus ~= false` and the terminal is focused. Under `create = "split"` the agent pane is a sibling of Neovim's pane in the same tab, so focus is a pane jump no heavier than the Neovim window jump `send` performs today. Under `create = "window"` it is a tab switch, which is the correct reading of "show me the agent" for a session the user deliberately put in its own tab.

**The call sits outside the just-attached gate.**
`State.attach` currently reports `Attached to` only when `attached` is true. Focus must not be gated the same way: the second and every later `send` to an already attached session has to focus too.

**`pane.focus { pane_id }` over the socket, not `herdr agent focus`.**
`agent focus` resolves against herdr's live agent registry, and that registry lags a freshly started tool. Measured on the exact sequence `start_native()` performs: `pane split` does not focus the new pane at all, `pane run exec env pi` returns at t+0ms, `agent focus` at t+0ms fails, and herdr first reports the agent at **t+590ms**, after which `agent focus` succeeds. Since `State.attach` focuses immediately after starting the session, `agent focus` would silently miss on exactly the send that creates the session — the send where being taken to the agent matters most — and work on every one after it.

`pane.focus` targets the pane rather than an agent inside it, so there is nothing to detect and nothing to race. It also covers a tool herdr never detects as an agent, which `agent focus` cannot, and it is the same call a future blur needs.

It has no CLI verb, so it goes over `HERDR_SOCKET_PATH` directly. Sidekick's existing socket code is a subscribe-only stream, so this adds a bounded request/response helper: connect, write one request, wait for the first response line, close. The wait is capped as a stuck-server backstop, not an expected cost — this is a local unix socket round trip, unlike polling an agent registry for half a second. Bounding it also keeps the ordering guarantee that focus resolves before the scheduled send.

When `HERDR_SOCKET_PATH` is unset — Neovim running outside a herdr pane with the backend forced — the helper reports failure and `focus()` falls back to `herdr agent focus`, because the CLI resolves herdr's socket on its own. That fallback keeps the agent-registry limitation, which is acceptable for a path that only exists outside a herdr pane.

An embedded session (`herdr_embedded`) returns early, exactly as `send` and `submit` already do — its tool runs in a Neovim terminal, which the terminal path already focuses, and Neovim's own pane is by definition where the user already is.

*Alternative considered:* keep `agent focus` and poll until the agent is detected. Rejected: `agent wait` returns `agent_not_found` immediately for an agent it does not know, so this needs a poll loop, and `Util.exec` is synchronous — it would block Neovim for roughly 600ms on every session start.

*Alternative considered:* focus the pane at creation time in `start_native()` instead. `pane split` does not focus the pane it creates (measured), and the only ungated way to focus a named pane is `pane.focus`, so this reduces to the same call in a worse place.

*Alternative considered:* `herdr pane focus --pane $HERDR_PANE_ID --direction <split direction>`. Rejected: it resolves by geometry, so it breaks as soon as the user rearranges panes, and it cannot address a pane in another tab.

**tmux gets `-p` on the same reasoning.**
`paste-buffer -p` wraps the buffer in bracketed paste. The defect and the fix are identical; only the primitive differs.

## Risks / Trade-offs

- **claude renders a framed payload of three or more lines as a collapsed placeholder.** Measured through sidekick: one line and two lines render inline, three lines become `[Pasted text #1 +3 lines]` with a `paste again to expand` hint. codex renders the same three lines inline. The content is delivered in full either way — this is presentation, not loss — but multi-line context is exactly what sidekick sends most (`{selection}`, `{file}`, `{diagnostics}`), so claude users will see this often. Accepted because the alternative is not inline text, it is corrupted text: the same payload sent unframed into a normal-mode composer loses its leading characters. There is no third option, since sidekick cannot tell whether a composer is modal or which mode it is in.
- **`pi` users running the `pi-vim` extension and sending from normal mode lose delivery instead of losing two characters.** Non-destructive and immediately visible, and recoverable by entering insert mode and resending. Recorded in `DEFECTS.md` against `github.com/lajarre/pi-vim` rather than papered over. This is the narrowest of the four cases: the modal composer is a third-party extension rather than the tool's own input layer, so every first-party composer measured handles the framing correctly.
- **Focus follows every send, which is a bigger interruption in `window` mode than in `split` mode.** `focus = false` opts out per call. Reconsider a `cli.mux.focus` config key only if this proves wrong in use; adding it now would be speculative.
- **Focusing marks the tab seen.** Per herdr's documented status model, targeting a pane or agent with a focus command marks it seen, which collapses `done` back to `idle`. Auto-focus on send therefore erases herdr's "unseen background work finished" signal for that agent. Acceptable, since the user is being taken to the pane.
- **`mux_focus` becomes redundant on the herdr path.** The qwen focus-in escape sequence exists because unfocused TUIs drop input; real focus supersedes it. Left in place for tmux, where focus is not yet implemented, and not removed here.
- **No paste-mode detection.** If a tool's composer has bracketed paste disabled, the literal `[200~` lands in its input. Every tool in the registry is a TUI that enables it, and herdr exposes no way to check, so this is accepted rather than guarded.
