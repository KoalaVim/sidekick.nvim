# NES Diff Rendering

## Purpose

Turns a next edit suggestion into something the user can see in the buffer: it computes a
line-level diff between the current text of the edit range and the suggested replacement text,
optionally refines changed lines down to word or character level, classifies the result into
context, added and deleted regions, and renders those regions as extmarks (inline virtual text,
virtual lines, line highlights and a sign) that can all be cleared again in one step.

## Requirements

### Requirement: Full-line diff of the suggested edit

The system SHALL expand a suggestion into two full-line texts before diffing: the `from` text is
the current content of the buffer lines spanned by the edit range (`edit.from[1]` through
`edit.to[1]`, inclusive), and the `to` text is that same span with the region between
`edit.from` and `edit.to` replaced by the suggestion's `text`, so the prefix of the first line
and the suffix of the last line are preserved. When the edit range refers to lines that do not
exist in the buffer, the `from` side SHALL be treated as a single empty line rather than raising
an error.

The line-level diff SHALL use the patience algorithm with zero context and zero inter-hunk
context and with line matching enabled, so one logical replacement MAY be reported as several
adjacent hunks. Each non-empty side SHALL be terminated with a newline before diffing and an
empty side SHALL be passed as the empty string, so a fully empty `from` or `to` side yields a
pure add or a pure delete rather than a change against a phantom empty line. The computed diff
SHALL also carry the virtual lines of both sides, syntax highlighted with treesitter when a
parser is available for the buffer's filetype, where every chunk of the `to` side additionally
carries `SidekickDiffAdd` as its background highlight. When no parser is available, both sides
SHALL fall back to a single unhighlighted chunk per line, so neither the syntax highlights nor
`SidekickDiffAdd` are present. The diff for an edit SHALL be computed once and reused for
subsequent renders of the same edit.

#### Scenario: Partial-line replacement is diffed as whole lines

- **WHEN** an edit replaces columns 6 to 9 of line 0 of a buffer containing `local foo = 1`
- **THEN** the `from` text SHALL be the whole line `local foo = 1`
- **AND** the `to` text SHALL be the whole line with only that column range replaced

#### Scenario: Append past the last line

- **WHEN** an edit range starts on a line index at or beyond the end of the buffer and its text
  is non-empty
- **THEN** the `from` side SHALL be an empty line, the `to` side SHALL be the suggested text,
  and the diff SHALL contain a single add hunk

#### Scenario: Filetype without a treesitter parser

- **WHEN** the edit's buffer has a filetype for which no treesitter parser can be loaded
- **THEN** every virtual line of both sides SHALL be a single chunk with no highlight, and the
  `to` side SHALL NOT carry `SidekickDiffAdd`

#### Scenario: Edit that changes nothing

- **WHEN** the `from` and `to` texts are both empty (for example a deletion whose range lies
  past the end of the buffer)
- **THEN** the diff SHALL contain zero hunks and the edit SHALL be reported as empty

### Requirement: Hunk classification and positioning

Every region of the diff SHALL be classified as `add` when it only inserts lines or tokens,
`delete` when it only removes them, and `change` when it does both. Each hunk SHALL record the
buffer position it is anchored at and how many lines of the `from` text it covers (`cover`),
where a block hunk covers the removed lines, an add-only block hunk covers zero lines, and an
inline hunk always covers exactly one line. Hunk rows SHALL be resolved relative to the first
line of the edit range and SHALL never be negative.
Added lines of a `change` hunk SHALL be anchored on the last line it removes, so the suggestion
appears directly below the text it replaces; added lines of an `add` hunk SHALL be anchored on
the line preceding the insertion point. Lines of the edit range that no hunk touches are context
and SHALL NOT be classified as added or deleted.

#### Scenario: Multi-line replacement

- **WHEN** a hunk removes several lines and inserts several lines
- **THEN** its kind SHALL be `change`, its `cover` SHALL be the number of removed lines, and its
  added lines SHALL be anchored on the last removed line

#### Scenario: Pure insertion between existing lines

- **WHEN** a hunk inserts lines without removing any
- **THEN** its kind SHALL be `add` and its `cover` SHALL be zero

#### Scenario: Hunk anchored outside the buffer

- **WHEN** an edit targets a line far beyond the end of the buffer
- **THEN** the diff SHALL still be computed and classified, and rendering an extmark at an
  invalid position SHALL be reported as an error notification instead of aborting the render

### Requirement: Inline refinement eligibility and tokenization

The `nes.diff.inline` option SHALL select the inline refinement mode and SHALL default to
`"words"`; the documented values are `"words"`, `"chars"` and `false`, and the option SHALL NOT
be validated at setup. When it is `false`, no refinement SHALL be attempted and every hunk SHALL
be rendered as a block. When refinement is
enabled, a hunk SHALL be eligible only when it removes and inserts the same number of lines and
that number is between one and three; all other hunks SHALL be rendered as blocks. In `"words"`
mode a line SHALL be tokenized into runs of keyword characters (per `iskeyword`) with every
other character as its own token; in any other enabled mode a line SHALL be tokenized into
individual UTF-8 characters. Tokens SHALL inherit the syntax highlight of the text they come
from. Token pairs SHALL be diffed with the minimal algorithm and an inter-hunk context of four
tokens, so nearby token hunks are merged into a single hunk.

Refinement SHALL be all-or-nothing per hunk: if refinement of any line of an eligible hunk is
rejected, the whole hunk SHALL fall back to block rendering. Refinement of a line SHALL be
rejected when the total byte length of the inserted tokens reaches half the byte length of the
resulting line or more, so an edit that rewrites most of a line is shown as a block instead of a
long inline insertion. Because that ratio is measured against the length of the resulting line, a
line whose `to` side is empty SHALL always be rejected and fall back to block rendering.

#### Scenario: Word-level change

- **WHEN** `nes.diff.inline` is `"words"` and an edit turns `foo` into `food` on one line
- **THEN** a single inline `change` hunk SHALL be produced whose position is the start of the
  `foo` token

#### Scenario: Character-level change

- **WHEN** `nes.diff.inline` is `"chars"` and an edit turns `foo` into `food` on one line
- **THEN** an inline `add` hunk for the single character `d` SHALL be produced

#### Scenario: Inline disabled

- **WHEN** `nes.diff.inline` is `false`
- **THEN** the same single-line edit SHALL produce one non-inline `change` hunk anchored at
  column 0 of the changed line

#### Scenario: Insertion dominates the new line

- **WHEN** a single-line edit inserts 20 characters into a line whose new length is 32
- **THEN** inline refinement SHALL be rejected and the hunk SHALL be rendered as a block

### Requirement: Inline rendering of refined hunks

An inline hunk SHALL be rendered on the line it belongs to, without virtual lines. Removed
tokens SHALL be highlighted in place with `SidekickDiffDelete` over the exact byte range they
occupy. Inserted tokens SHALL be rendered as inline virtual text carrying whatever highlights
their `to`-side chunk carries (its syntax highlight plus `SidekickDiffAdd` when treesitter
highlighting is available, and no highlight at all otherwise), positioned immediately after the
removed range when the hunk also removes text, and otherwise immediately after the token
preceding the insertion point.
Insertions before the first token SHALL be placed at column 0 and insertions after the last
token SHALL be placed at the end of the line.

#### Scenario: Replacement of a word

- **WHEN** an inline `change` hunk replaces columns 6 to 9 with `food`
- **THEN** columns 6 to 9 SHALL be highlighted with `SidekickDiffDelete` and `food` SHALL be
  shown as inline virtual text at column 9

#### Scenario: Insertion at the start of a line

- **WHEN** an inline hunk inserts text before the first token of the line
- **THEN** the inserted tokens SHALL be rendered as inline virtual text at column 0 and no
  delete highlight SHALL be added

#### Scenario: Insertion at the end of a line

- **WHEN** an inline hunk appends text after the last token of the line
- **THEN** the inserted tokens SHALL be rendered as inline virtual text at the end of the line

#### Scenario: Deletion only

- **WHEN** an inline hunk only removes tokens
- **THEN** it SHALL produce exactly one decoration: the `SidekickDiffDelete` highlight over the
  removed byte range

### Requirement: Rendering added lines as virtual lines

Lines inserted by a block hunk SHALL be rendered as virtual lines attached to the hunk's anchor
row, below the text they replace, using the syntax-highlighted `to` text so the suggestion is
readable as code. Each virtual line SHALL be padded to a common block width with
`SidekickDiffAdd` and SHALL be followed by filler highlighted with `SidekickDiffContext` so the
block reads as a contiguous region across the window. Common leading indentation SHALL be
stripped and replaced with `SidekickDiffContext`. The block width SHALL be one column wider than
the widest line participating in the block hunks of the whole diff, so all rendered blocks of one
suggestion align. When a hunk inserts nothing, no virtual lines SHALL be created for it.

#### Scenario: Added block below a replaced line

- **WHEN** a block `change` hunk replaces one line with one line
- **THEN** the suggested line SHALL be rendered as a virtual line below the replaced line,
  highlighted as an added block

#### Scenario: Common alignment width

- **WHEN** the widest line of the diff's block hunks is 32 columns wide
- **THEN** the added block SHALL be padded to width 33

#### Scenario: Pure deletion

- **WHEN** a hunk only removes lines
- **THEN** no virtual lines SHALL be rendered for it

### Requirement: Rendering deleted lines

Every line removed by a block hunk SHALL be highlighted as deleted for its whole line using
`SidekickDiffDelete`, and SHALL be followed, starting one column past the widest line of the
block hunks, which is the column where the padded add block ends, by filler highlighted with
`SidekickDiffContext`, so deleted lines and added blocks form one aligned region. Inline hunks
SHALL NOT mark their line as deleted.

#### Scenario: Removed line

- **WHEN** a block hunk removes a line
- **THEN** that line SHALL carry the `SidekickDiffDelete` line highlight and context-highlighted
  filler to the right of the block

#### Scenario: Multi-line removal

- **WHEN** a block hunk removes three lines
- **THEN** all three lines SHALL be highlighted as deleted

### Requirement: Context background across the edit range

Lines of the edit range not covered by a block hunk SHALL be given a full-line
`SidekickDiffContext` background, extending past the end of the line, after the hunks of the edit
are rendered. This SHALL include lines that were refined inline, so an inline change still reads as
part of the suggestion. Lines beyond the end of the buffer SHALL be skipped.

#### Scenario: Line refined inline

- **WHEN** a line of the edit range carries only inline decorations
- **THEN** it SHALL also receive the `SidekickDiffContext` background

#### Scenario: Unchanged line inside the range

- **WHEN** a line of the edit range is unchanged by the suggestion
- **THEN** it SHALL receive the `SidekickDiffContext` background

#### Scenario: Range extends past the buffer

- **WHEN** the edit range ends past the last line of the buffer
- **THEN** the context background SHALL be applied only up to the last existing line

### Requirement: Diff visibility modes

The `nes.diff.show` option SHALL control when the diff decorations are rendered and SHALL default
to `"always"`; its only accepted values are `"always"` and `"cursor"`, and any other value SHALL
be reported as a configuration error. With `"always"`, the diff SHALL be rendered whenever a
suggestion is active. With `"cursor"`, the diff SHALL be rendered only while the edit's buffer is
the current buffer and the cursor line lies within the edit range (`edit.from[1]` through
`edit.to[1]` inclusive); otherwise only the sign SHALL be rendered. In `"cursor"` mode the
rendering SHALL be refreshed as the cursor moves, so entering the range reveals the diff and
leaving it hides the diff again while the suggestion stays active.

#### Scenario: Always mode

- **WHEN** `nes.diff.show` is `"always"` and a suggestion is active
- **THEN** the diff SHALL be rendered regardless of the cursor position

#### Scenario: Cursor inside the edit range

- **WHEN** `nes.diff.show` is `"cursor"`, the edit's buffer is current, and the cursor is on a
  line inside the edit range
- **THEN** the full diff SHALL be rendered

#### Scenario: Cursor outside the edit range

- **WHEN** `nes.diff.show` is `"cursor"` and the cursor is outside the edit range or in another
  buffer
- **THEN** no diff decorations SHALL be rendered and only the sign SHALL remain visible

#### Scenario: Invalid mode

- **WHEN** `nes.diff.show` is set to a value other than `"always"` or `"cursor"`
- **THEN** setup SHALL report an error naming the option, the found value and the expected values

### Requirement: Sign column indicator

A sign SHALL be placed on the first line of the edit range using `ui.icons.nes` as its text and
`SidekickSign` as its highlight. The sign SHALL be rendered when `nes.signs` is enabled (the
default) and SHALL also be rendered regardless of `nes.signs` when `nes.diff.show` is `"cursor"`,
so a suggestion whose diff is currently hidden is still discoverable. When `nes.signs` is
disabled and `nes.diff.show` is `"always"`, no sign SHALL be rendered.

#### Scenario: Signs enabled

- **WHEN** `nes.signs` is `true` and a suggestion is rendered
- **THEN** a sign with the configured `ui.icons.nes` icon SHALL appear on the first line of the
  edit range

#### Scenario: Signs disabled in cursor mode

- **WHEN** `nes.signs` is `false` and `nes.diff.show` is `"cursor"`
- **THEN** the sign SHALL still be rendered even while the diff itself is hidden

#### Scenario: Signs disabled in always mode

- **WHEN** `nes.signs` is `false` and `nes.diff.show` is `"always"`
- **THEN** no sign SHALL be rendered and only the diff decorations SHALL be visible

### Requirement: Highlight groups

The rendering SHALL use four overridable highlight groups on top of the syntax highlights of the
text itself, each defined as a default link so a user or colorscheme can override it:
`SidekickDiffAdd` (linked to `DiffText`) for suggested text,
`SidekickDiffDelete` (linked to `DiffDelete`) for text that will be removed,
`SidekickDiffContext` (linked to `DiffChange`) for the surrounding and filler regions of the
suggestion, and `SidekickSign` (linked to `Special`) for the sign. These links SHALL be
re-established when the colorscheme changes.

#### Scenario: Default links

- **WHEN** the plugin is set up without highlight overrides
- **THEN** the four groups SHALL exist as default links to `DiffText`, `DiffDelete`,
  `DiffChange` and `Special`

#### Scenario: User override survives

- **WHEN** the user defines `SidekickDiffAdd` explicitly
- **THEN** the user definition SHALL win over the plugin's default link

#### Scenario: Colorscheme change

- **WHEN** the colorscheme changes
- **THEN** the default links SHALL be applied again

### Requirement: Clearing rendered decorations

All decorations of a suggestion SHALL live in a single dedicated namespace and SHALL be
removable in one step. Buffers that have been rendered into SHALL be marked, and clearing SHALL
clear the namespace in every marked buffer and remove the mark, leaving unmarked buffers
untouched. Re-rendering SHALL clear all previous decorations first, so decorations never
accumulate across renders. An edit whose diff contains no hunks SHALL produce no decorations
beyond the marking of its buffer, and SHALL be logged when debug logging is enabled.

#### Scenario: Clearing after rendering

- **WHEN** a suggestion has been rendered and is then cleared
- **THEN** every decoration, including the sign, the inline virtual text, the virtual lines and
  the context background, SHALL be removed from the buffer

#### Scenario: Re-render replaces decorations

- **WHEN** the rendering is refreshed (for example while the cursor moves in `"cursor"` mode)
- **THEN** previous decorations SHALL be cleared before the new ones are placed

#### Scenario: Empty diff

- **WHEN** an edit's diff contains no hunks
- **THEN** no decorations SHALL be placed for it and clearing SHALL remain a no-op for its
  content
