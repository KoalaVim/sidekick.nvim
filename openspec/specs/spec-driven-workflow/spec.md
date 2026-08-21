# Spec-Driven Workflow

## Purpose

Defines the contract a human or agent must satisfy when changing this repository's behavior: how
capability specs are laid out and validated, what artifacts a change must carry and in what order,
how a change's delta specs are written and merged back into the specs that serve as the current
source of truth, and how a finished change is archived. It governs the repository's own planning
process under the OpenSpec CLI; it states no behavior of the Neovim plugin itself.

## Requirements

### Requirement: Workflow schema declaration

The repository SHALL declare its planning workflow in `openspec/config.yaml` with `schema: spec-driven`,
which is the schema every change in this repository uses. The file MAY also carry a `context` field
holding project background and a `rules` field holding per-artifact rules keyed by artifact id
(`proposal`, `specs`, `design`, `tasks`); both are optional and are currently present only as commented
examples. Where `context` or `rules` are set, the CLI SHALL surface them through
`openspec instructions <artifact> --json`, and they SHALL be treated as constraints on what the author
writes rather than as content to be copied into the artifact.

#### Scenario: Schema resolution for a new change

- **WHEN** a change is created in this repository without naming a schema
- **THEN** it SHALL be created with the `spec-driven` schema, and `openspec status --change <name> --json`
  SHALL report `schemaName` as `spec-driven`

#### Scenario: Project context and rules are unset

- **WHEN** `openspec/config.yaml` carries no `context` or `rules` value
- **THEN** artifact creation SHALL proceed on the schema's own instructions alone, and no context or
  rules block SHALL appear in any artifact

#### Scenario: Rules are constraints, not content

- **WHEN** `openspec instructions` returns a `context` or `rules` payload for an artifact
- **THEN** the author SHALL apply it while writing and SHALL NOT reproduce it inside the artifact file

### Requirement: Specs, active changes and archive layout

Current behavior SHALL live in capability specs at `openspec/specs/<capability>/spec.md`, one directory
per capability, named in kebab-case; these specs are the source of truth for what the plugin does today.
Work in flight SHALL live at `openspec/changes/<change-name>/`, also kebab-case, and a completed change
SHALL be moved to `openspec/changes/archive/<YYYY-MM-DD>-<change-name>/`. A capability SHALL own each
behavior exactly once; the `ai-integration` capability records which capability owns which part of the
AI CLI flow and is the routing table a change consults before choosing its delta targets.

#### Scenario: Enumerating the source of truth

- **WHEN** `openspec list --specs` is run at the repository root
- **THEN** it SHALL list every capability under `openspec/specs/` with its requirement count

#### Scenario: Enumerating work in flight

- **WHEN** `openspec list --json` is run and no directory other than `archive` exists under
  `openspec/changes/`
- **THEN** the reported `changes` array SHALL be empty, and archived changes SHALL NOT be reported as
  active

#### Scenario: Archived changes are read-only history

- **WHEN** an archived change's delta spec disagrees with the capability spec under `openspec/specs/`
- **THEN** the capability spec SHALL be taken as current and the archived delta SHALL be treated as the
  historical record of one change

### Requirement: Capability spec structure

A capability spec SHALL open with a single `#` title, then a `## Purpose` section, then a
`## Requirements` section. Each requirement SHALL be a `### Requirement: <name>` heading whose body
contains at least one RFC-2119 normative keyword (`SHALL` or `MUST`), and SHALL carry at least one
scenario written as a level-4 `#### Scenario: <name>` heading followed by `- **WHEN**` / `- **THEN**`
bullets. Scenario headings at any other level SHALL NOT be recognized. `openspec validate --specs`
SHALL pass for every capability spec in the repository.

#### Scenario: Validation gate

- **WHEN** `openspec validate --specs` is run after a capability spec is added or edited
- **THEN** every spec SHALL be reported as passing and the command SHALL report zero failures

#### Scenario: Requirement without a scenario

- **WHEN** a requirement carries no `#### Scenario:` block
- **THEN** validation SHALL fail with an error against that requirement's scenarios

#### Scenario: Requirement without a normative keyword

- **WHEN** a requirement's body contains neither `SHALL` nor `MUST`
- **THEN** validation SHALL fail with an error against that requirement's text

#### Scenario: Missing required section

- **WHEN** a spec omits `## Purpose` or `## Requirements`
- **THEN** validation SHALL fail against the file, naming the expected headers

### Requirement: Change artifact set and dependency order

A change SHALL consist of a `proposal.md` stating why and what, delta specs under `specs/`, a `design.md`
stating how, and a `tasks.md` implementation checklist. `openspec new change <name>` SHALL scaffold only
the change directory and its `.openspec.yaml`; the artifacts themselves are authored. The CLI SHALL report
the dependency order: `proposal` is ready first, `specs` and `design` each require `proposal`, `tasks`
requires both `specs` and `design`, and implementation requires `tasks`. An artifact whose dependencies
are unmet SHALL be reported as blocked with its missing dependencies named. The proposal's `Capabilities`
section, split into new and modified capabilities, SHALL name every capability that needs a delta spec and
SHALL be the contract between the proposal and the specs it produces.

#### Scenario: Freshly created change

- **WHEN** `openspec new change <name>` has just run
- **THEN** the change directory SHALL contain only `.openspec.yaml`, and `openspec status --change <name>
  --json` SHALL report `proposal` as ready and `specs`, `design` and `tasks` as blocked

#### Scenario: Tasks are authored last

- **WHEN** the delta specs and the design are complete
- **THEN** `tasks` SHALL become ready, and `applyRequires` SHALL name `tasks` as the artifact implementation
  depends on

#### Scenario: Capability naming follows the proposal

- **WHEN** the proposal lists a new capability
- **THEN** the delta SHALL be written at `specs/<that-exact-kebab-case-name>/spec.md`, and a modified
  capability SHALL reuse the existing directory name from `openspec/specs/`

#### Scenario: Design is scoped to real design work

- **WHEN** a change involves an architectural decision, a new dependency, or a trade-off worth recording
- **THEN** `design.md` SHALL capture context, goals and non-goals, decisions with the alternatives
  considered, and risks, rather than restating the proposal

### Requirement: Task checklist convention

`tasks.md` SHALL group work under numbered `## N. <group>` headings and SHALL express every task as a
checkbox line of the form `- [ ] N.M <description>`. Progress SHALL be tracked by rewriting `- [ ]` to
`- [x]` as each task lands, and a task SHALL be marked complete as soon as its work is done rather than
in a batch at the end. Lines that do not use the checkbox form SHALL NOT be counted as tasks.

#### Scenario: Progress is derived from checkboxes

- **WHEN** `openspec list --json` is run for an active change
- **THEN** `completedTasks` and `totalTasks` SHALL reflect the `- [x]` and `- [ ]` lines in `tasks.md`,
  and a change with no tasks file SHALL be reported with status `no-tasks`

#### Scenario: Implementation reveals a problem

- **WHEN** a task turns out to be ambiguous or contradicts the design
- **THEN** implementation SHALL pause and the artifacts SHALL be revised, rather than the task being
  guessed at or silently reinterpreted

### Requirement: Delta spec format

A change's delta spec at `openspec/changes/<name>/specs/<capability>/spec.md` SHALL express its intent
through `## ADDED Requirements`, `## MODIFIED Requirements`, `## REMOVED Requirements` and
`## RENAMED Requirements` sections, including only the sections it needs. Requirements and scenarios inside
a delta SHALL follow the same `### Requirement:` and `#### Scenario:` shape as a capability spec. A
`MODIFIED` entry SHALL reproduce the whole requirement block it replaces, with a heading matching the
existing one, so that no detail is lost at merge time; a concern that adds behavior without changing
existing behavior SHALL use `ADDED` instead. A `REMOVED` entry SHALL state a `Reason` and a `Migration`.
A `RENAMED` entry SHALL use the `FROM:` / `TO:` form and SHALL change nothing but the name.

#### Scenario: New capability delta

- **WHEN** a change introduces a capability that has no spec under `openspec/specs/`
- **THEN** its delta SHALL consist of `ADDED Requirements` alone

#### Scenario: Reshaping existing behavior

- **WHEN** a change alters behavior an existing requirement already describes
- **THEN** that requirement SHALL appear in full under `MODIFIED Requirements` with the new behavior
  written in, not as a fragment or a diff

#### Scenario: Dropping behavior

- **WHEN** a change removes a requirement
- **THEN** the `REMOVED` entry SHALL name the requirement and SHALL explain why it is going and what users
  of the old behavior do instead

#### Scenario: A delta is intent, not a replacement file

- **WHEN** a delta spec touches one requirement of a capability that has many
- **THEN** it SHALL NOT be treated as the capability's new spec, and requirements it does not mention SHALL
  survive the merge untouched

### Requirement: Delta specs are merged into main specs by sync

Syncing a change SHALL fold its delta specs into `openspec/specs/<capability>/spec.md` as an
author-performed, judgment-based merge rather than a mechanical file replacement. `ADDED` requirements SHALL
be inserted, or updated in place if a requirement of that name already exists; `MODIFIED` requirements SHALL
be applied to the matching requirement while preserving scenarios and prose the delta does not mention;
`REMOVED` requirements SHALL be deleted whole; `RENAMED` requirements SHALL be renamed. Where the capability
has no spec yet, sync SHALL create `openspec/specs/<capability>/spec.md` with a Purpose and the added
requirements. Sync SHALL leave the change active, and the merged specs SHALL still satisfy
`openspec validate --specs`. Sync SHALL be idempotent.

#### Scenario: Partial update preserves the rest

- **WHEN** a `MODIFIED` entry adds one scenario to an existing requirement
- **THEN** that scenario SHALL be added and the requirement's other scenarios SHALL remain

#### Scenario: Running sync twice

- **WHEN** sync is performed a second time for the same change with no intervening edits
- **THEN** the main specs SHALL end up in the same state as after the first run

#### Scenario: Sync does not end the change

- **WHEN** sync completes
- **THEN** the change SHALL remain under `openspec/changes/<name>/` and SHALL still be reported as active

#### Scenario: A neighboring requirement is left inconsistent

- **WHEN** merging a delta leaves a requirement the delta never listed describing behavior that no longer
  exists
- **THEN** the inconsistency SHALL be resolved in the main spec as part of the sync, and the reason SHALL be
  recorded in the commit that performs it

### Requirement: Archiving a completed change

Archiving SHALL move the whole change directory to `openspec/changes/archive/<YYYY-MM-DD>-<change-name>/`,
where the date is the archive date and not the change's `created` date. Every artifact SHALL travel with the
directory, including `.openspec.yaml`, so an archived change stays self-describing. If the target path
already exists the archive SHALL fail rather than overwrite. Incomplete artifacts and unchecked tasks SHALL
produce a warning and an explicit confirmation rather than a hard block; where a task is archived unchecked,
the reason SHALL be stated. Before archiving, any unsynced delta specs SHALL be assessed and the merge SHALL
be offered.

#### Scenario: Archive target naming

- **WHEN** a change named `rework-herdr-session-modes` is archived on 2026-08-21
- **THEN** it SHALL come to rest at `openspec/changes/archive/2026-08-21-rework-herdr-session-modes/`,
  retaining its `.openspec.yaml` recording `schema: spec-driven` and its original `created` date

#### Scenario: Target already exists

- **WHEN** an archive directory of that date and name is already present
- **THEN** the archive SHALL fail and SHALL NOT merge into or replace the existing directory

#### Scenario: Unfinished work at archive time

- **WHEN** `tasks.md` still has `- [ ]` entries, or an artifact is not complete
- **THEN** the shortfall SHALL be reported and confirmed before the move, and the archived `tasks.md` SHALL
  keep those entries unchecked

#### Scenario: Unsynced deltas at archive time

- **WHEN** a change carries delta specs that have not been folded into `openspec/specs/`
- **THEN** the pending merge SHALL be summarized and syncing SHALL be offered before the change is archived

### Requirement: Agent entry points are mirrored across runtimes

The workflow SHALL be driven through five agent entry points: propose a change and generate its artifacts,
apply the change by working its tasks, sync delta specs into the main specs, archive a completed change, and
explore a problem before committing to a change. Explore SHALL read and reason but SHALL NOT write
implementation code, though it MAY capture thinking into OpenSpec artifacts. Each entry point SHALL be
available to every supported agent runtime: as a skill under `.claude/skills/`, `.codex/skills/` and
`.cursor/skills/`, whose instruction text is byte-identical across the three, and as a slash
command under `.claude/commands/opsx/` and `.cursor/commands/`, whose bodies are identical and whose
front matter differs only in the naming each runtime requires.

#### Scenario: Skill definitions stay in step

- **WHEN** one of the five `SKILL.md` files is added or edited
- **THEN** the copies under `.claude/skills/`, `.codex/skills/` and `.cursor/skills/` SHALL remain identical
  in content

#### Scenario: Command definitions stay in step

- **WHEN** an `opsx` slash command body is changed
- **THEN** the `.claude/commands/opsx/<name>.md` and `.cursor/commands/opsx-<name>.md` bodies SHALL remain
  identical below their front matter

#### Scenario: Explore mode is asked to implement

- **WHEN** the user asks for code while exploring
- **THEN** no implementation code SHALL be written, and the user SHALL be directed to propose a change first
