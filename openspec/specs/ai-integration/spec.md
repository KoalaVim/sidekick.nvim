# AI Integration

## Purpose

Defines requirements for integrating external AI command-line tools into a sidecar panel within the editor, including session management, tool selection, and mux backend support.

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
