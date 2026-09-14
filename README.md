# Tychedit

A two-pane Markdown editor for macOS that understands
[mdship](https://pypi.org/project/mdship/) placeholders and runs mdship for
you. Text on the left, preview on the right. The companion editor to Diptych.

Most markdown editors show mdship placeholders as nothing at all: they are HTML
comments, and the browser hides them. Tychedit shows them, suggests and checks
their parameters as you type, and tells you what `mdship update` will think of
your edits before you run it.

## Building

Requires Xcode 26 and macOS 15 or later. No third-party dependencies.

```bash
./build.sh              # Debug build
./build.sh run          # build and launch
./build.sh run file.md  # build and launch on a file
./build.sh test         # unit tests (the mdship tests run only when mdship is installed)
./build.sh release      # optimised build
./build.sh path         # where the .app is
```

To open a file from outside the app: Finder's **Open With**, Diptych, or
`open -a Tychedit file.md`. The app registers as an *alternate* editor for
markdown and plain text; it becomes the default for `.md` files only if you say
Yes when it asks at start-up.

## Settings and files in ~/.tychedit

| File | What it holds |
|---|---|
| `settings.json` | Every setting from the Settings window, as readable JSON. Edits made by hand take effect when you switch back to Tychedit. A missing key takes its default; a file that cannot be read is copied to `settings.broken.json` before Tychedit writes a new one. |
| `recent.json` | File ▸ Open Recent, newest first. How many files it remembers is set in Settings ▸ Editing. |
| `NOT_DEFAULT_EDITOR` | Present only if you answered "No, Don't Ask Again" (see below). |

**Default Markdown editor.** At start-up, unless `~/.tychedit/NOT_DEFAULT_EDITOR`
exists, Tychedit checks whether it is the default application for Markdown files
for your user. If it is not, it asks: **Yes** makes it the default (macOS may ask
you to confirm), **Not Now** asks again next time, and **No, Don't Ask Again**
creates `NOT_DEFAULT_EDITOR`, a file explaining that deleting it brings the
question back. The default is set for the copy of Tychedit that asks, so saying
Yes to a development build from `./build.sh run` points Markdown files at that build.

## Windows and files

**One window per file.** Opening a file that is already open brings its window
forward instead of opening it twice. That holds wherever the request comes from:
the Open panel, Finder, a link in the preview, or a followed reference.

**Saving is automatic** for files that have a location on disk. Tychedit saves:
- after changes have waited a while (30 seconds by default; set it in Settings);
- when a window loses focus, or you switch to another app;
- before any mdship command runs.

An autosave never lands mid-word, never interrupts, and never overwrites a file
that changed on disk. That conflict is asked about when you come back to the
window. Untitled documents are not saved automatically. Closing a window or
quitting saves what can be saved and asks about the rest.

**Saving is byte-faithful.** mdship keeps checksums of generated content inside
the file, so a save changes only what you edited. Encoding, byte order mark,
line endings, file permissions and extended attributes all stay as they were.

**Changes on disk**, from `mdship` in a terminal, git, or Diptych, are picked up
when the window becomes active. If there are no unsaved edits, the file reloads,
and **Undo** brings back the previous text.

## Find and replace

**⌘F** opens the find bar above the editor; **⌘R** opens it with the replace
row too. The search field starts with the selected text, when there is some.
- Three switches change how it matches, and are remembered in `settings.json`:
  - **Aa**: match case;
  - **W**: whole words only;
  - **.\***: regular expression. The replacement can then use `$1`, `$2` …
    for the groups, and `^` and `$` match at line starts and ends.
- Every match is highlighted and counted ("2 of 7").
- Return or ⌘G goes to the next match; ⇧Return or ⇧⌘G goes to the previous.
- In the replace field, Return replaces the selected match and moves on.
- **All** replaces every match as one change, so a single Undo takes it back.
- Escape or **Done** closes the bar.

## Editing mdship placeholders

**Parameter suggestions.** Inside a placeholder's opening comment, typing brings
up the parameters that placeholder accepts, each with a one-line explanation.
Required parameters come first; parameters already present are left out.
Suggestions also know nested structure: the keys of an AI `deps:` entry, and
`pattern`/`include` under INCLUDE's `start:` and `end:`.

Values are suggested too:
- the choices for `strategy`, `format` and `theme`;
- `true`/`false`;
- `@heading` and `@version` for SUP patterns;
- **file names from disk** for `from:`, `brief:`, `deps: path:` and MERMAID `file:`;
- script names from `.mdship/scripts/` for `run:`, `define:`, `transform:` and `audit:`.

Arrow keys choose, Return or Tab inserts, and Escape closes. ⌃Space (or Escape,
or ⌥Esc) asks for suggestions at any time; picking a folder continues into it.

**Starting a placeholder.** Typing `<!--` and a letter offers the placeholders
starting with it: `<!--I` offers IMPORT and INCLUDE. Once the name is complete,
the editor offers to close the comment:
- a placeholder with a closing tag gets a new line, `-->`, and `<!--/INCLUDE-->`;
- one without gets only `-->`;
- MERMAID also gets the empty line where the image goes;
- PYTHON offers both its `run:` form and its `define:` form.

Accepting puts the caret on the empty line inside the comment, with the
parameter list open. ⌃Space on an empty line outside any placeholder offers
whole placeholders, ready to fill in.

⌃Space is also macOS's default shortcut for switching input sources. If that
shortcut is on in System Settings ▸ Keyboard ▸ Keyboard Shortcuts, the system
takes the key first; Escape and ⌥Esc still work.

**Checks as you type.** Problems are tinted and underlined (red for errors,
orange for warnings), with a message in the status bar when the caret is on them, and
an entry in the problems menu. The editor recognises:

- unknown parameters, with a suggestion for likely typos (`form` → *did you mean `from`?*)
- missing required parameters
- values of the wrong kind:
  - a list where a single value belongs
  - `margin: two`
  - `max-level: 9`
  - an unknown `strategy`
  - a quoted `"yes"` for a boolean
- regular expressions that do not compile, or have the wrong number of capture
  groups: SUP and SIP need one, SLURP rules need two
- `@pattern` references that no SET defines
- combinations mdship rejects or ignores:
  - `range` with `section`
  - PYTHON with both `run` and `define`
  - `transform` on PYTHON
  - `binary: true` with a range
- duplicate SET variables and duplicate AI placeholder names
- **paths that point nowhere**:
  - a missing `from:` file
  - a directory where a file is required
  - a missing script in `.mdship/scripts/`
  - an INCLUDE `range` that runs past the end of the file

Paths resolve the way mdship resolves them: relative to the markdown file, or
absolute. Scripts resolve from the nearest `.mdship` folder above the document.

On top of that come the structural checks mdship itself runs, in mdship's own
words: unclosed placeholders, typos in closing tags, bad nesting, and generated
content edited by hand, which mdship would refuse to overwrite.

**About versions.** The parameter knowledge comes from mdship 1.2.5's source. An
installed mdship of another version may accept slightly different parameters.
mdship's own run is final, and whatever it reports appears in the problems menu
next to the editor's findings.

**In the editor**, the markdown is styled while it stays plain text:
- headings are larger and bold, by level;
- `**bold**`, `*italic*` and `~~strikethrough~~` look the part, markers included;
- inline code and fenced code blocks are grey;
- placeholder comments are purple, with their YAML keys in bold indigo;
- variable references are teal, and other HTML comments faint.

**Preview.** Every placeholder shows as a small card, generated content is
framed, and variable references show a `$name` label. **View ▸ Show Placeholders
in Preview** (⇧⌘P) switches to the reader's view.

## Following links and references

⌘-click, or **Navigate ▸ Open Link or Referenced File** (⌃⌘J):

| On | Goes to |
|---|---|
| `from: "src/api.py"` in INCLUDE, IMPORT, SLURP, SIP; `brief:`; `deps: path:` | the file, in its own window |
| INCLUDE `from:` with `range: "40..60"` | the file, at line 40 |
| INCLUDE `from:` with `start: "START"` | the file, at the first line after the match (the match itself with `include: true`) |
| INCLUDE `from:` with `section: Usage` | the file, at that heading |
| `run:`, `define:`, `transform:`, `audit:` | the script in `.mdship/scripts/` |
| `[text](other.md#setup)` | the file, at that heading |
| `[text](#setup)` | the heading in this document |
| `<!--$config.host-->` | where `config` is defined: the SET key, or the IMPORT/SLURP/SIP/SUP `name` |
| a web address | the browser |

Text files open in Tychedit, reusing a window if the file is already open.
Images and other files open in their own application, and folders open in
Finder. A link to a file that does not exist offers to create it. Links clicked
in the preview behave the same way.

## Gutter, line numbers and folding

The strip left of the text holds, from left to right:
- **what changed since the last git commit**, for files in a git repository:
  a green bar for added lines, a blue bar for changed lines, and a red wedge
  where committed lines were deleted. It is compared with `git show HEAD:file`
  when the file opens and whenever its window becomes active, so a commit made
  in a terminal or in Diptych shows up. Hovering over a change shows what the
  committed text was: the committed lines in red, the current ones in green.
  Right-click to put it back:
  - **Revert This Line** (or **Remove This Added Line**);
  - **Revert Whole Change**, for a change of several lines;
  - **Restore Deleted Lines**, on a red wedge.

  Each revert is one undoable edit. If the line has been edited since the
  gutter was drawn, nothing happens, rather than the wrong line changing.
- **line numbers**: off, absolute (1, 2, 3…), or relative to the caret as in
  vi, where the caret's own line shows its absolute number. The line-numbers
  button at the left of the toolbar steps through the three; **View ▸ Line
  Numbers** and Settings ▸ Editing set them too. The gutter keeps room for three
  digits, so it does not change width while a document under 1,000 lines is edited.
- **fold chevrons.**

Folding works on sections and placeholders:
- A **section** folds from its heading to the next heading of the same or a
  higher level.
- A **placeholder with a closing tag** has two chevrons. The left one folds it
  all, from `<!--INCLUDE` to `<!--/INCLUDE-->`. The right one folds only the
  opening comment, leaving `<!--INCLUDE [from: chapter.md] -->` above the
  content.
- A placeholder without a closing tag, such as a multi-line SET, has one
  chevron, which folds its comment.

A folded region shows a badge with what it hides. For a placeholder that is its
first parameter, so the parameter you list first is the one you see. Click the
badge or the chevron to open it again. **View ▸ Fold** (⌥⌘←), **Unfold** (⌥⌘→),
**Fold All** (⌥⇧⌘←) and **Unfold All** (⌥⇧⌘→) work from the caret.

Folding only hides text on screen: saving, find, undo and mdship see the whole
document. When the caret moves into folded text (Go to Line, Find, a jump to a
problem), that fold opens. Folds stay folded while you edit elsewhere, and
through an mdship update. A fold is recognised by the text of its first line,
so if mdship changes that line (for example, by numbering a heading), that fold opens.

## Running mdship

The **mdship** menu, with the current file saved first:

- **Update Placeholders** (⇧⌘U, also in the toolbar), and **Update Placeholders,
  Overwriting Edits** (`--force`, after a confirmation)
- Update Table of Contents, Update Includes, Render Diagrams
- Number Headings, Remove Heading Numbers, Fix Heading Levels, Promote and Demote
  Headings. Commands marked *(Selection or All)* act on the selected lines when
  there is a selection.
- Format Tables, Semantic Line Breaks, Reflow Paragraphs
- Validate Links, Check AI Placeholders, Add Checksum, Verify Checksum

After a command that changes the file, the editor shows the result as one
undoable change: **Undo** takes back what mdship did. Problems mdship reports
with a line number go into the problems menu. Everything mdship prints is
collected in **mdship ▸ Show Console** (⇧⌘M), and appears there while the
command is still running, so a long install shows its progress.

**Toolbar buttons.** Settings ▸ Toolbar chooses which mdship commands have a
toolbar button, in what order, and the icon of each (any SF Symbol name). The
same icons appear in the mdship menu. **mdship ▸ Restart mdship MCP Server**
stops the server; the next command starts a fresh one.

**How it talks to mdship.** Tychedit starts one `mdship mcp` server on first use
and keeps it running for every window, so a command does not pay Python's
start-up time. Link validation has no MCP tool, so it runs `mdship validate` on
the command line.

**Finding and installing mdship.** An app started from the Dock does not get
your terminal's PATH, so Tychedit asks your login shell where `mdship` is. That
works with pyenv, `~/.local/bin` and Homebrew alike. If mdship is not found,
**mdship ▸ Install or Upgrade mdship…** runs `python3 -m pip install --upgrade
mdship` in your login shell. You can also set the path explicitly in
**Settings ▸ mdship**. Settings also holds the numbering style, the reflow width,
and whether mdship keeps `.bak` backups; that is off by default, since Tychedit
saves first and can undo.

## Keyboard

|                                              |                          |
| -------------------------------------------- | ------------------------ |
| New / Open / Save / Save As / Close          | ⌘N / ⌘O / ⌘S / ⇧⌘S / ⌘W  |
| Find / Find and Replace                      | ⌘F / ⌘R                  |
| Find Next / Previous, Use Selection for Find | ⌘G / ⇧⌘G, ⌘E             |
| Show completions                             | ⌃Space, Esc or ⌥Esc      |
| Open link or referenced file                 | ⌘-click or ⌃⌘J           |
| Go to Line                                   | ⌘L                       |
| Next / Previous Heading                      | ⌃⌘↓ / ⌃⌘↑                |
| Next / Previous Placeholder                  | ⌃⌥⌘↓ / ⌃⌥⌘↑              |
| Next / Previous Problem                      | ⌘' / ⇧⌘'                 |
| Bold / Italic / Code / Strikethrough / Link  | ⌘B / ⌘I / ⌥⌘C / ⇧⌘X / ⌘K |
| Shift Right / Left                           | ⌘] / ⌘[                  |
| Move Line Up / Down                          | ⌥⌘[ / ⌥⌘]                |
| Duplicate Line / Delete Line                 | ⌘D / ⇧⌘K                 |
| mdship Update / Console                      | ⇧⌘U / ⇧⌘M                |
| Fold / Unfold / Fold All / Unfold All        | ⌥⌘← / ⌥⌘→ / ⌥⇧⌘← / ⌥⇧⌘→  |
| Bigger / Smaller / Actual Size               | ⌘+ / ⌘- / ⌘0             |

## Layout

```
Tychedit/
  TycheditApp.swift              app, delegate (open events, quit, autosave on deactivate)
  Model/Document.swift           one file: load, save, autosave, render and validate, mdship runs, navigation
  Model/DocumentController.swift windows by file, opening and reusing them, the autosave timer
  Model/Preferences.swift        shared settings
  Model/TextFile.swift           byte-faithful reading and writing
  Editor/EditorController.swift  NSTextView (TextKit 1): editing commands, underlines, completion keys
  Editor/CompletionProvider.swift  what to suggest at the caret
  Editor/CompletionPopup.swift   the suggestion list
  Editor/ReferenceFinder.swift   what a ⌘-click leads to
  Editor/EditorGutter.swift      change bars and fold chevrons
  Editor/EditorFolding.swift     hiding folded text in the layout manager
  Editor/Folding.swift           which lines fold together
  Editor/LineChanges.swift       comparing with the committed version from git
  Editor/SyntaxHighlighter.swift how each part of the markdown is drawn in the editor
  Model/DefaultEditor.swift      the start-up question about the default Markdown editor
  Placeholders/PlaceholderScanner.swift    placeholder structure, as mdship's validator sees it
  Placeholders/PlaceholderSchema.swift     every placeholder's parameters, from mdship's source
  Placeholders/PlaceholderValidator.swift  parameter, value and path checks
  Placeholders/YAMLOutline.swift           placeholder YAML with source positions
  Mdship/MCPClient.swift         the long-running `mdship mcp` server over stdio
  Mdship/MdshipService.swift     finding, installing and calling mdship; the console
  Mdship/MdshipCommand.swift     the commands and their tool arguments
  Mdship/MdshipEnvironment.swift login-shell PATH, process running
  Markdown/                      markdown to HTML, placeholder cards, data-line for scroll sync
  Preview/                       WKWebView, local-file scheme, link handling
  Views/                         SwiftUI window content, status bar, menus, Settings, console
TycheditTests/                   scanner, validator, completion, references, renderer, editor, files,
                                 and integration tests against the installed mdship
```

The renderer is written for this app rather than taken from a library, for two
reasons. A library would hide exactly the HTML comments this editor exists to
show. And every block needs its source line (`data-line`) for scroll sync.

