# AI Integration

## Purpose

Umbrella capability for the AI CLI sidecar feature as a whole. It states the end-to-end,
user-visible contract that spans several narrower capabilities, and records which capability
owns each part of the flow so that a change proposal can route its delta specs correctly.
It deliberately states no behavior that a narrower capability already owns.

## Requirements

### Requirement: AI CLI sidecar panel

The system SHALL integrate external AI command-line tools into a side panel within the editor. The panel SHALL support toggling visibility, showing/hiding, and selecting between multiple installed AI tools. Each tool session SHALL be independently manageable (attach, detach). When running inside a herdr environment (`HERDR_ENV=1`), the system SHALL support running agent sessions in herdr panes via the herdr mux backend, making them natively visible to herdr's agent detection.

#### Scenario: Toggle AI panel
- **WHEN** the user presses the AI toggle key
- **THEN** the AI sidecar panel SHALL open (or close if already open)

#### Scenario: Select AI tool
- **WHEN** the user triggers tool selection
- **THEN** a picker SHALL show all available AI CLI tools, and selecting one SHALL switch the active tool

#### Scenario: Detach session
- **WHEN** the user detaches the current AI session
- **THEN** the session SHALL be disconnected from the panel, freeing it for a new session

#### Scenario: Herdr-backed session visible to herdr
- **WHEN** an AI tool is started with the herdr mux backend active
- **THEN** herdr SHALL natively detect the agent with correct status (idle/working/blocked) without any custom reporting bridge

### Requirement: One tool-agnostic path from editor context to a running agent

Sending context to an AI tool SHALL follow one path regardless of which tool, session backend, or window layout is in play: capture editor context, render it into message text, resolve or start a session for the tool in the current working directory, and deliver the text to that session. A tool SHALL NOT be required to implement anything beyond its definition fields to participate in this path, and a session backend SHALL NOT be required to implement anything beyond the backend contract.

#### Scenario: Same request across different tools
- **WHEN** the same prompt is sent while two different configured tools are active in turn
- **THEN** context capture, template expansion, session resolution and delivery SHALL behave identically apart from the tool's own definition fields

#### Scenario: Same request across different backends
- **WHEN** the same prompt is sent to a session hosted in a Neovim terminal and to one hosted in a multiplexer pane
- **THEN** the caller SHALL use the same public entry point, and the backend difference SHALL affect only where the tool process lives

#### Scenario: Adding a tool requires no new integration code
- **WHEN** a user adds a tool that ships no definition file by configuring it under `cli.tools`
- **THEN** the tool SHALL be selectable, startable, and able to receive context without changes to any other capability

### Requirement: Capability ownership of the AI CLI feature

The AI CLI feature SHALL be specified across dedicated capabilities rather than in this umbrella, and each behavior SHALL have exactly one owning capability. A change that alters AI CLI behavior SHALL write its delta spec against the owning capability below, and SHALL amend this umbrella only when the end-to-end contract itself changes.

#### Scenario: Routing a delta for tool definitions
- **WHEN** a change alters how a tool is declared, discovered, or matched to a running process
- **THEN** the delta SHALL target the `cli-tool-registry` capability

#### Scenario: Routing a delta for sessions and the panel
- **WHEN** a change alters the public CLI entry points, session state and status classification, or the selection picker
- **THEN** the delta SHALL target the `cli-session-management` capability, and window layout or keymap changes SHALL target `cli-terminal-window`

#### Scenario: Routing a delta for context and prompts
- **WHEN** a change alters context providers, placeholder expansion, or prompt templates
- **THEN** the delta SHALL target the `cli-context-and-prompts` capability, and file or buffer selection UI SHALL target `file-pickers`

#### Scenario: Routing a delta for multiplexer behavior
- **WHEN** a change alters tmux, zellij, or shared scrollback behavior
- **THEN** the delta SHALL target the `mux-session-backends` capability, and herdr-specific behavior SHALL target `herdr-mux-backend`

#### Scenario: Routing a delta for buffer synchronization
- **WHEN** a change alters how buffers are reloaded after an AI tool edits files on disk
- **THEN** the delta SHALL target the `file-change-watch` capability
