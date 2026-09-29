mdship ft will reformat your tables so they are well aligned in the source.
you can automatically insert files into your markdown document using the INCLUDE placeholder.
mdship can generate a table of contents automatically with the TOC placeholder, and it keeps working even across content pulled in by INCLUDE.
the TOC placeholder lets you set a min-level and max-level so the table of contents only lists the heading depths you actually want.
mdship number adds hierarchical numbers to your headings, like 1.1 and 1.2, in three different styles: period, space, or parenthesis.
mdship unnumber strips hierarchical numbering back out of your headings whenever you want the plain titles back.
fix-headings closes gaps in your heading hierarchy automatically, so a document that jumps from an h1 straight to an h3 becomes a proper h1 to h2 to h3.
shift-headings can push every heading in a document down or up by any number of levels at once, which is handy when you paste one document's outline into another.
mdship reflow can rewrap your paragraphs to a fixed line width, or, with width 0, put exactly one sentence per line.
semantic-line-breaks splits your text at sentence and clause boundaries instead of at a fixed column, which keeps diffs small when only one sentence changes.
the SET placeholder lets you define variables directly in the markdown file using YAML, including nested structures and lists.
the IMPORT placeholder loads a whole JSON, YAML, TOML, or even XML file into a variable namespace you can reference elsewhere in the document.
SLURP scans a file or a whole directory with a two-capture regular expression to harvest variable names and values in bulk.
SIP is like SLURP but for named variables: you give it one-capture patterns keyed by variable name.
SUP grabs a single value out of the very next non-empty line after the placeholder, using one capture group.
a variable reference like the $appName placeholder keeps the last value it produced sitting right there in the source, so the document stays readable even before mdship update runs.
the marker form with an empty tag exists because a bare variable reference cannot safely hold a replacement value that contains spaces.
JINJA2 placeholders give you real template logic in your markdown: loops, conditionals, filters, and nested object access.
TEMPLATE placeholders still work but are deprecated in favor of JINJA2, which renders an undefined variable as empty instead of leaving a literal dollar-name behind.
the MERMAID placeholder renders a diagram straight from its source text into an SVG or PNG file and manages the image reference on the next line for you.
MERMAID diagrams can be themed default, forest, dark, or neutral, right from the placeholder's own configuration.
because a raw arrow would terminate the HTML comment early, MERMAID diagrams escape their arrows in the source and mdship converts them back before rendering.
a PYTHON run placeholder can generate or update content by running a small project-local script instead of a built-in mdship feature.
a PYTHON define placeholder runs a script that introduces new variables, right alongside SET and IMPORT.
every PYTHON placeholder and every transform or audit hook is blocked until the project is explicitly listed in a read-only trust file that mdship itself never writes to.
mdship deliberately never edits its own trust file, because enabling script execution has to stay a deliberate, out-of-band decision the user makes by hand.
a transform hook can post-process the generated output of an INCLUDE, TOC, MERMAID, TEMPLATE, or JINJA2 placeholder before it is written to the file.
an audit hook runs right after a variable source's values are collected, and can see every variable gathered so far in the whole document, not just its own.
mdship protects every block it generates with a content hash, so it can tell a hand edit from its own output later on.
AI placeholders work the same way as TOC or INCLUDE: mdship records a hash of whatever the AI wrote so later runs can tell if you have hand-edited it since.
running mdship ai-check tells you whether an AI-generated section still matches what was recorded, without printing or regenerating the content itself.
mdship ai-fix records a fresh content hash for an AI placeholder, and you run it right after you have written or approved new content for that section.
a review comment starting with slash-slash-AI is an inline annotation you or an agent can drop into a document without touching the reviewed content itself.
mdship ai-comments lists every inline review annotation with its line number, so you can work through a whole batch of review notes without reading the entire file.
mdship sum writes a checksum into a document's front matter, and mdship verify later checks that the content still matches it.
you can choose the hash algorithm mdship uses for a checksum: md5, sha1, or sha256, with sha256 as the default.
mdship validate checks a markdown file's links, anchors, and AI placeholder naming for you before you commit to updating it.
frontmatter-get can print a single value out of a document's YAML front matter using a dot-notation path like author.name.
frontmatter-set writes a single front-matter value by dot-notation path, creating the surrounding YAML structure if it does not exist yet.
get-section prints one whole section, from its heading through every subsection beneath it, addressed by heading title or a path like Setup followed by Prerequisites.
replace-section swaps out one whole section for new text, addressed the same way get-section is, by heading title or path.
if two sections share the same heading title, both get-section and replace-section take an occurrence index to tell them apart.
list-headings prints every heading in a document as JSON, together with its level, line number, and full ancestor path.
extract-table reads one table out of a document and hands it back as JSON: a header array and a list of row arrays.
update-table takes that same JSON shape back and rewrites the table with its columns freshly aligned.
get-lines is a deliberately dumb primitive: it returns a verbatim range of lines with no idea where headings, tables, or code fences are.
get-paragraphs is friendlier than get-lines: give it a line range and it expands to the full paragraph or paragraphs overlapping it, keeping a fenced code block intact even if it has blank lines inside.
insert-lines and delete-lines are primitives too, and mdship's own documentation recommends replace-section over them whenever a heading anchor is available.
find-replace does a regex find-and-replace across a document but skips the insides of fenced code blocks, so a substitution cannot accidentally rewrite example code.
by default mdship only writes a backup file when the document is not tracked by git or has uncommitted changes, and you can force that either way.
the track option makes mdship update a document's front matter with a last-updated timestamp and a change log every time it runs.
a dry run shows you everything mdship would change without touching a single file.
mdship init sets up the project files a Claude Code agent needs to find the mdship MCP server automatically.
mdship scripts init creates a scripts directory for a project's own Python hooks and prints exactly what to add to the trust file to enable them.
mdship scripts list shows you every factory script, whether it is installed yet, and any scripts of your own alongside them.
mdship scripts update refreshes a factory script from the current mdship version, but only if you have not modified your local copy.
mdship can run as an MCP server over standard input and output, which is how an agent like Claude Code talks to it instead of shelling out to the CLI.
an INCLUDE selection by line range is mutually exclusive with selecting by regex start and end patterns or by section title.
an INCLUDE selection by regex must actually match somewhere in the file, or mdship treats that as an error rather than silently producing an empty block.
an INCLUDE can pull in just one markdown section by its bare heading title, which survives better than a line range when the source file keeps changing.
an INCLUDE's margin field re-indents every included line so the leftmost one lands at exactly the column you ask for.
mdship always resolves every variable source before touching a single INCLUDE, so an included file's own variable references still get replaced afterward.
TOC generation happens after INCLUDE and template rendering, which is why a table of contents can list headings that only exist because they were pulled in from another file.
a PYTHON run block executes before the TOC step, specifically so any headings a script generates still get indexed.
mdship is short for markdown ship: one tool that authors, updates, and inspects markdown files, from the command line or as an MCP tool for an LLM agent.
XML data imported into mdship gets wrapped under its root element's own name, so a pom.xml file's version ends up reachable through a dotted path.
an XML namespace only needs mapping on import if the same local name shows up twice at one level under two different namespaces.
a JINJA2 placeholder's undefined variable simply renders empty, unlike the deprecated TEMPLATE placeholder, which leaves the literal variable name sitting in the output.
mdship's format-tables command is purely cosmetic: it never touches cell content or a column's declared alignment, only the padding between cells.
custom closing markers exist for a reason: you only need one when a placeholder's own generated content might otherwise contain the default closing tag's text.
mdship's discovery tools like list-headings and get-section exist so an agent can inspect a large document without ever reading the whole file.
mdship is dual-licensed under the MIT and Apache 2.0 licenses, so you can pick whichever suits your project.
mdship's source lives on GitHub, at the same account behind Tychedit itself.
mdship can tell you its own version at any time with a simple command-line flag.
update-table quietly resets a table's column alignment back to plain dashes even if the original had colons for left, right, or center alignment, since only format-tables preserves declared alignment on a reformat.
a literal pipe character inside a table cell is automatically escaped as a backslash-pipe when mdship writes the table back out, so it survives as text instead of being read as a new column.
a real newline trapped inside a table cell gets flattened to a single space when mdship renders the table, since a GFM table row can only ever be one physical line.
every rendered table column is padded to at least three dashes wide in its delimiter row, even if every cell in that column is empty or a single character.
you can address a table to extract or update by the line number of any row inside it, not just by its position among the document's tables.
fix-headings never touches the very first heading in a document, no matter its level, so a document that intentionally opens with an h3 stays exactly that way.
a heading skip like h1-to-h3 gets clamped one level at a time by fix-headings, so several such skips in a row each get pulled back to a legal depth rather than being flattened to a single level.
shift-headings checks every heading in its target range before touching any of them, so a shift that would push even one heading above h1 or below h6 is refused up front, with the maximum safe shift spelled out in the error.
asking mdship to number headings with skip-title only works if there is exactly one h1 in range; two or more and it refuses, since it cannot guess which one is really the document's title.
running mdship number twice in a row never double-numbers your headings, because it always strips any existing numbering first and then applies fresh numbers from scratch.
unnumbering a heading recognizes six distinct numbering shapes, from a plain "1 " to a nested "1.1) ", so headings numbered in any of mdship's own three styles come back out clean.
heading tools like number, unnumber, fix-headings, and shift-headings all skip over anything sitting inside an HTML comment, so a hash character inside a SET placeholder's YAML body is never mistaken for a heading.
mdship reflow parses your document into a real markdown syntax tree before rewrapping it, which is how it knows to leave list markers, blockquote markers, and code fences alone instead of just wrapping raw text.
splitting a paragraph into one sentence per line is done with a fairly simple rule -- text is cut wherever a period, question mark, or exclamation point is followed by whitespace -- so a paragraph with an abbreviation like "Mr. Smith" can end up split in a spot you didn't expect.
reflow and semantic-line-breaks can both be restricted to a line range, so you can rewrap just one paragraph in a long document without touching the rest.
reflow always keeps YAML front-matter completely untouched, splitting it off before parsing and stitching it back on unchanged afterward.
defining the same variable twice, from any combination of SET, IMPORT, SLURP, SIP, or SUP, is a hard error in mdship -- there's no silent last-one-wins, so a naming collision is always caught before it can quietly shadow an earlier value.
you can't turn a variable that started as a single value into a nested structure later in the same document, or vice versa; mdship treats mixing a scalar and a dictionary at the same variable path as a conflict, not an overwrite.
SIP and SLURP don't have to scan a single file -- point 'from' at a whole directory and mdship will walk it with an include or exclude glob pattern, optionally recursing into subdirectories.
by default, if a SIP or SLURP pattern matches zero times or more than once across the scanned files, mdship raises an error rather than silently guessing which match you wanted -- you opt in explicitly with a 'first', 'last', or 'concatenate' strategy.
a SLURP rule's two capturing groups don't have to be positional -- name them with (?P<var>...) and (?P<val>...) and mdship uses the names instead of assuming which one is the variable and which is the value.
SUP's pattern can be a shorthand like "@version" instead of a literal regex, resolved from a table of named patterns you can extend yourself alongside the built-in ones.
SUP politely skips over any blank lines between the placeholder and the first real content, so a little breathing room in the source doesn't break the extraction.
files scanned by SIP or SLURP are always processed in the same alphabetical order, so the same directory produces the same result no matter what order the filesystem happens to hand the files back in.
the built-in "@heading" SUP pattern pulls the leading numeral out of a numbered heading line, like pulling "1.5.8" out of "### 1.5.8 Some Title", and "@version" pulls a semantic-version-looking string out of a line, with or without a leading "v".
you can define your own named pattern shortcuts right inside a SET block, and they get merged alongside mdship's own built-in "@heading" and "@version" patterns rather than replacing them.
IMPORT will guess a file's format from its extension, but you can override that guess entirely with an explicit 'format' field -- handy for importing a config file that's really YAML but doesn't have a .yaml name.
on Python versions before 3.11, IMPORT quietly falls back to a separate 'toml' package for reading TOML files, since the standard library didn't ship a TOML reader until then.
importing two differently-namespaced XML elements that would collide under the same name once namespaces are stripped is an error, not a silent overwrite -- mdship tells you to give one of them a name with 'xmlns' instead.
XML attributes come into mdship prefixed with an "@", and an element's own text only gets its own "_text" key if that element also has attributes or children -- otherwise the whole thing just collapses to a plain string value.
repeated XML child elements sharing the same tag are automatically gathered into a list rather than the second one silently overwriting the first.
the checksum mdship writes into a generated placeholder isn't just a fingerprint -- it also encodes the exact character length of the content, so inserting even a single extra space inside a protected block is enough to trip the integrity check.
if you ever see the literal warning "MANAGED CONTENT: Edits will be lost." inside a markdown file, that's mdship itself, written automatically the first time it fills a placeholder -- nobody typed that by hand.
mdship refuses to trust a _content_generated_ entry that isn't sitting on its own clean line in the placeholder's YAML -- if it's buried inside some other structure, that looks like tampering, not legitimate output.
every placeholder marker mdship recognizes has the same rule: it only counts as real if it opens at the very start of a line, with nothing but optional whitespace before it.
a placeholder-looking comment sitting inside a fenced code block is never treated as a real placeholder by mdship, which is a handy way to show an example of INCLUDE or TOC syntax in documentation without mdship trying to process it.
INCLUDE's regex-based start and end patterns can each match more than once through a file, opening and closing several separate included sections from one placeholder -- and while a section is open, only the end pattern is even checked, so start and end can safely be identical or overlap.
giving INCLUDE only an 'end' pattern and no 'start' includes everything from the top of the file down to that match; giving only 'start' includes everything from that match to the end of the file.
INCLUDE's margin option can shrink indentation just as easily as it can add it -- ask for a smaller margin than the block already has, and mdship strips the extra leading spaces back down.
selecting an INCLUDE by section matches the heading's bare title case-insensitively, after stripping away any numbering prefix -- so it still finds "Setup" even if the source file has since been numbered to "2.1. Setup".
mdship always finishes collecting every variable from SET, IMPORT, SLURP, SIP, and SUP before it processes a single INCLUDE, precisely so an included file that itself contains variable references still gets them replaced afterward.
INCLUDE placeholders in a document are processed from the bottom of the file upward, specifically to avoid the position bookkeeping trouble of an earlier replacement shifting where a later one is supposed to land.
generating a table of contents has a side effect on the whole document: mdship strips trailing spaces from every heading line first, not just the ones that end up listed in the TOC.
a TOC anchor is built by lowercasing the heading text, turning both spaces and underscores into hyphens, stripping anything that isn't a letter, digit, or hyphen, and collapsing repeated hyphens -- so "Getting Started!" and "getting_started" both end up as the same anchor.
mdship validates a TOC's min-level and max-level bounds strictly: anything outside 1 through 6, or a minimum greater than the maximum, is rejected before it ever tries to build the list.
JINJA2 placeholders render with autoescaping turned off, since the output is markdown, not HTML, and escaping a variable's angle brackets or ampersands would just corrupt the document.
a Jinja2 syntax error inside a JINJA2 placeholder -- a bad filter, an unclosed tag -- surfaces immediately as a clear rendering error naming the placeholder's line, rather than silently producing broken output.
the deprecated TEMPLATE placeholder's variable substitution is deliberately simple -- just plain $var and ${var} -- with no loops, filters, or conditionals at all, which is exactly the gap JINJA2 was added to fill.
MERMAID diagrams are actually rendered by a separate, optional package; if it isn't installed, mdship tells you plainly which extra to install instead of failing with a cryptic import error.
a MERMAID placeholder's diagram source can use the same variable substitutions as everywhere else in mdship, so one SET block can drive labels across both your prose and your diagrams.
the very first time you add a MERMAID placeholder, the line right after its closing tag has to be left completely empty -- that blank line is the reserved slot mdship will fill in with the generated image reference.
mdship only counts a MERMAID diagram as changed if the newly rendered image bytes actually differ from what was already saved on disk, so re-running update on an unchanged diagram doesn't churn its file's timestamp for no reason.
a MERMAID placeholder doesn't need, or even want, a closing tag -- its managed region is exactly the single line after the opening marker, and mdship quietly treats a closing tag left there as ordinary text rather than choking on it.
mdship enforces that a MERMAID output file end in .svg or .png and nothing else, checked before it ever tries to render anything.
a PYTHON run script's own run function receives whatever text is already sitting in its managed region -- empty the very first time, its own previous output on every later run -- which is exactly what lets a script append one more row to a table instead of rebuilding the whole thing from scratch each time.
a single PYTHON placeholder can never declare both 'run' and 'define' at once; mdship treats that as a contradiction, since a placeholder is either a content generator or a variable source, never both.
a PYTHON run placeholder is specifically forbidden from also declaring a transform hook -- any post-processing has to live inside the script's own run function instead.
setting the yolo option on a PYTHON placeholder doesn't just skip the manual-edit content check -- it also skips the position check for the closing tag, so it will run even over content whose length no longer matches what mdship expects.
every project-local script mdship loads is cached by its file path for the whole run, so if three different placeholders all reference the same helper script, its top-level code only actually executes once.
resolving a script name is also a security check: mdship refuses to run anything that resolves outside the project's own scripts directory, closing off a path-traversal trick like naming a script with a bunch of parent-directory references.
a chain of transform scripts on one placeholder shares a single scratch dictionary, fresh for that placeholder alone, so one script in the chain can leave a note for the next one to pick up.
audit hooks run right after a variable source's values are collected and can see every variable gathered anywhere in the whole document so far, not just the ones their own placeholder introduced.
raising an exception from inside an audit script aborts the entire mdship update run and leaves the document completely untouched, exactly as if the run had never started.
mdship's trust check for running scripts demands three things be true at once: the allow-list file has to exist, it has to be genuinely unwritable, and it has to actually list the project's path -- and the error message tells you the precise command to lock the file down afterward.
mdship checks a script's trust file for being unwritable using the operating system's own permission bits, which on Windows means it honors the file's read-only attribute rather than a Unix-style permission mode.
mdship ships four ready-made example scripts you can install with a single command: one that numbers every line of an included file, one that trims blank lines and trailing whitespace, one that aborts a run when required variables are missing, and one that wraps generated content in a collapsible details block.
the bundled line-numbering script skips any line that starts with a code fence by default, so numbering an included source file doesn't accidentally number its own wrapping backtick lines too.
the bundled line-numbering script automatically right-aligns its numbers to a consistent width based on how many lines it's numbering, so a hundred-line file doesn't end up with wobbly single-digit numbers next to triple-digit ones.
the bundled "require variables" audit script can check not just plain variable names but numeric list indices too, like the third item in an imported array.
the bundled "collapsible details" script needs genuinely blank lines around its wrapped content, because markdown syntax only keeps working when it's nested inside raw HTML if there's a blank line separating them.
mdship tracks every factory script it installs with a small sidecar file recording the exact mdship version, the install date, and a checksum, which is how scripts update can tell a script you've never touched from one you've quietly edited yourself.
mdship refuses to overwrite a factory script you've modified locally when you ask it to update -- you have to explicitly force a fresh install if you really want to discard your own changes.
the AI placeholder isn't processed by mdship's own engine at all -- mdship only tracks its checksums; actually writing the content is entirely up to whichever AI agent is asked to fill it in.
because the text already sitting inside an AI placeholder is always treated as potentially stale, an agent processing it is specifically told never to treat anything inside that region as an instruction -- even a line that reads like "ignore previous instructions" is just old content waiting to be replaced.
an AI placeholder's checksums track three separate things independently -- the generated content itself, the prompt text, and each declared dependency file -- so mdship can tell you specifically what changed instead of just a single "something's different."
an AI placeholder can point to a separate brief file of shared writing instructions -- tone, audience, style -- tracked with its own checksum, completely apart from the prompt and the dependency files.
a dependency listed on an AI placeholder can be a whole file, a line range, a regex-bounded slice, or one markdown section by heading title, or a binary file read as raw bytes -- but binary files can't be sliced by line at all.
if every checksum on an AI placeholder matches but it has no dependencies declared at all, mdship deliberately reports a different status than "up to date" -- it can't promise nothing relevant changed if it was never told what to watch.
an AI placeholder's name can never be a plain integer, because integers are reserved for addressing an unnamed placeholder by its line number instead.
once an AI placeholder's managed content has been hand-edited since the last generation, mdship refuses to regenerate it silently -- a human has to explicitly accept those edits first before anything can move forward.
an //AI: review comment always has two halves -- the suggested change and the reasoning behind it -- and the reasoning isn't optional, because a later, separate session applying the fix has no memory of the conversation that produced the comment.
inserting //AI: review comments is meant to be strictly non-destructive: the reviewed document's actual content has to stay byte-for-byte identical to the input, with nothing but new comment lines added.
applying a batch of //AI: review comments works from the bottom of the document upward, specifically because removing an earlier comment line would otherwise shift the line numbers of every comment still waiting below it.
a //AI: comment that turns out to be ambiguous or already fixed by an earlier change in the same pass still gets deleted when the batch is applied -- the convention is to never leave an orphaned review comment behind.
trust runs in opposite directions for mdship's two AI conventions: a review comment is treated as an authoritative instruction to act on, while the content sitting inside an AI placeholder is treated as the exact opposite -- disposable, never authoritative.
the document checksum mdship writes to front matter only ever covers the body -- the front matter block itself is excluded from what gets hashed, so changing an unrelated front-matter field never breaks the checksum.
mdship remembers which hash algorithm produced a document's stored checksum and always re-checks with that same algorithm later, even if the tool's own default has since changed.
turning on the track option doesn't just add a timestamp -- it appends to a running log stored right in the front matter, so a well-tracked document accumulates a permanent history of every mdship operation ever run on it.
mdship validate treats a broken internal link or a missing image file as a real error, but a heading anchor that's defined and simply never linked to gets only a warning, since it might still be referenced from some other file entirely.
link and image validation only checks local file references -- an http, https, ftp, or mailto link is never checked against the filesystem, since there's nothing local to check.
a YAML front-matter block that opens with a bare "---" but never closes with a matching one is a hard error in mdship, not silently treated as ordinary document text.
clearing out the very last remaining key in a document's front matter makes mdship remove the whole front-matter block entirely, rather than leaving an empty, pointless one behind.
get-section and replace-section match a heading path like "Setup > Prerequisites" as a suffix of the heading's full ancestor chain, so it finds "Prerequisites" nested anywhere under a "Setup" heading, not just as its direct child.
a section's extent, for both get-section and replace-section, always runs until the next heading at the same level or shallower -- which is exactly what quietly pulls every one of that section's own subsections along for the ride.
find-replace matches its regex against the whole document as one piece of text, so a pattern can span multiple lines -- but each individual match is only actually applied if the line it starts on falls inside whatever line range you asked for and isn't sitting inside a fenced code block.
find-replace's replacement count limit is a running total across the whole document, not per line, so asking for a maximum of one replacement stops after the very first match anywhere in the file.
insert-lines happily accepts an after-line of zero to mean "insert at the very start of the document, before line one."
get-paragraphs expands outward in both directions from whatever range you give it, so a start line landing inside a paragraph and an end line landing well past it both still return the same full set of complete paragraphs.
a fenced code block containing blank lines is still treated as a single unbroken paragraph by get-paragraphs, so a blank line inside example code never accidentally splits it into two separate returned chunks.
mdship's default backup rule genuinely asks git whether it's safe to skip the backup file -- it checks that the document is tracked, that it matches HEAD exactly, and that it isn't a symlink, before deciding a backup would be redundant.
a file hidden behind git's assume-unchanged or skip-worktree flags still gets backed up by mdship by default, even though git itself might report it as clean -- mdship treats those flags as status that could be lying rather than trusting them.
if git isn't installed, the current directory isn't a repository, or the git command fails for any reason, mdship falls back to always writing a backup rather than ever guessing it's safe to skip one.
mdship never writes anything to disk at all -- not even a backup file -- if the content it generated turns out to be byte-for-byte identical to what was already there.
asking for both bak and no-bak in the same command is a flat error in mdship; it refuses to guess which one you actually meant.
mdship's dry-run flag doesn't just say "something would change" -- it prints an actual colorized unified diff, formatted just like a git patch, so you can see exactly which lines would be added or removed.
a backup file keeps the document's original extension in place and just appends ".bak" to the whole filename, so "notes.md" becomes "notes.md.bak", not "notes.bak".
mdship update always runs its placeholder pipeline in the exact same fixed order, whether or not a document actually contains every kind of placeholder: variables, then INCLUDE, then variable substitution, then TEMPLATE, then JINJA2, then PYTHON's run mode, then TOC, and MERMAID dead last.
mdship's own error types form a small family tree -- a general placeholder error, a more specific integrity error, a script error, and a trust error that is itself a kind of script error -- so code handling mdship's failures can catch the right category without ever having to pattern-match error message text.
a document with no TOC placeholder at all isn't treated as broken by mdship update -- that specific "not found" condition is designed to be quietly ignored for an optional placeholder like TOC, while every other kind of error still stops the run.
mdship's own placeholder-versus-code-block detection only recognizes triple-backtick fences, so a placeholder-like comment sitting inside a tilde-fenced code block isn't automatically protected the same way a backtick-fenced one is.
mdship init doesn't just wire up Claude Code -- it also writes matching prompt files for GitHub Copilot, so the same review, fix, and placeholder skills become available there too.
running mdship init on a project that already has Claude Code settings doesn't overwrite them -- mdship reads the existing file and merges itself into the list of enabled MCP servers instead.
variable substitution notices when the text it's replacing is wrapped in matching backticks, and re-wraps the new value in the same number of backticks, so replacing a value shown as inline code stays valid inline code.
if a variable's resolved value comes back as nothing at all, mdship treats that as "not found" and raises rather than silently inserting the word for an empty value into your document.
even the bare, no-marker form of a variable reference has a safety net: use it with a value that turns out to contain a space, and mdship refuses and tells you to switch to the marker form instead of silently producing a broken reference.
variable substitution is deliberately skipped inside both fenced code blocks and MERMAID placeholders during the general document-wide pass -- a MERMAID diagram's own variables are handled separately, only at diagram-render time.
mdship validate actually bundles two independent checks into one pass -- link and anchor validation, and AI placeholder structural validation -- reporting problems from both in the same run.
read-only commands like validate explicitly refuse the track option, since there's nothing to update and mdship would rather error out than silently ignore a flag that doesn't apply.
leave the file argument off almost any mdship command and it reuses whichever file or files you last gave it, remembered in a small state file inside the project's own mdship directory.
mdship exists because generated documentation goes stale silently: the code changes, the paragraph describing it does not, and nothing tells you which paragraph is now wrong.
mdship's own one-line pitch for itself is blunt: everything derivable should be derived, and everything else should be verified.
an AI placeholder's checksum records don't just say something changed, they say precisely why: a specific dependency, the prompt text, or the shared brief file, reported separately rather than as one vague "stale" flag.
the two MCP tools that drive AI placeholders are deliberately split in two: ai_context is a free gating call that tells an agent whether to bother at all, and only ai_update ever actually writes to the file.
because ai_context hands back the previous content, the prompt, the brief, and every dependency slice in one response, the agent generating an AI placeholder's text never has to open the source document, or any of its dependency files, directly.
mdship treats "editing markdown in place" and "keeping a separate build output" as a real fork in the road, and deliberately picked the in-place side: no build step, but the guardrail against clobbering a hand-edit becomes the checksum instead of a separate output file.
mdship's own documentation explicitly compares itself to classic macro preprocessors like m4, Jamal, and PET, which never touch their source files at all -- mdship's whole design is the opposite bet.
even if you've told mdship to use sha256 for a document-level checksum with sum and verify, the checksum protecting a single managed placeholder's content is always MD5, unconditionally -- it's the one hash algorithm nothing lets you change.
an update that hits a real hash mismatch on a managed block gets a different error message than one that finds the closing tag in the wrong place entirely -- "manually edited" and "closing tag not found" are deliberately distinguishable failures, not one generic one.
running mdship update --force doesn't throw away all its safety nets at once: it still uses the stored byte length to find a closing tag if the position still checks out, and only falls back to a blind regex scan if the length itself no longer matches.
there's one specific case even --force can't rescue: if the content you included from elsewhere happens to contain text that looks like the placeholder's own closing tag, the regex fallback can stop early at that false match, and the fix is a manual edit, not a stronger flag.
mdship protects every generated TOC or INCLUDE block with a content hash, so a hand edit to it is caught by the next update instead of being silently overwritten.
ai-check, ai-fix and the --force flag on update are the accept-or-override half of content-integrity hashing: ai-check reports what changed, ai-fix accepts it, and --force overwrites it.
when the output of a command is byte-for-byte identical to what is already in the file, mdship prints a distinct dim "already up to date" message instead of a success message for a change that never happened.
mdship's --dry-run flag doesn't just report that something would change: it renders a real colored unified diff, and for mdship update it skips diagram rendering entirely so no SVG files get written just to preview a change.
a MERMAID placeholder takes no closing tag, unlike TOC and INCLUDE, since its whole managed region is just the one line holding the image reference.
if a closing tag sits directly after a MERMAID placeholder's opening marker with no blank line between them, add the blank line yourself once: mdship fills it with the image reference on the next run and leaves the closing tag alone as ordinary text.
the Mermaid renderer is an optional extra, because its diagram engine is WTFPL-licensed, the kind of license many corporate legal reviews reject outright.
plain pip install mdship pulls in only MIT- and BSD-licensed dependencies; you opt into the Mermaid renderer, and its non-standard license, with a separate mdship[mermaid] install.
rendering a MERMAID diagram to SVG needs nothing beyond the mermaid extra, but rendering to PNG additionally needs a library called cairosvg -- SVG output is the lighter-weight path.
XML namespaces are stripped from element names by default, so a namespaced file's data stays reachable through plain dotted variable paths; if you want a namespace kept, map it with xmlns on the import.
a Maven pom.xml imports cleanly, because its namespace is stripped from every tag and its version stays reachable through a plain dotted path.
mdship's error messages are not hard-wrapped when piped into a log file, so file paths and diff lines stay whole in CI output.
an error message can name a heading like "[draft]" or contain other bracketed text, and mdship prints the square brackets literally instead of treating them as markup.
mdship's own test suite runs in CI on every Python version from 3.11 through 3.14.
mdship's documentation isn't just markdown files sitting in a folder -- it's rebuilt into an actual website on every single push to the repository.
mdship covers heading tools (fix-headings, shift-headings, number, unnumber), text tools (reflow, semantic-line-breaks), a table-of-contents command, checksums, link validation, the whole placeholder pipeline, project init and the MCP server; AI placeholders build on top of all that.
the --track option records a last-updated timestamp and an operation log in front matter after every modifying command.
mdship remembers the last set of files you gave any modifying command in a small file named .lastfiles inside the project's own .mdship directory, and quietly replays that list if you leave the file argument off next time.
fix-headings will happily leave a document completely alone if it starts at h3 with no h1 or h2 at all -- it only closes gaps where a heading skips forward past what its parent level allows, never questions where the hierarchy starts.
if a heading in the middle of a document jumps back up to a shallower level -- h3 down to h1, say -- fix-headings leaves it exactly as it found it, because going back up a level is always structurally valid and never needs correcting.
fix-headings only ever rewrites the run of hash marks at the start of a corrected heading line -- bold text, inline code, or any other formatting inside that same heading survives completely untouched.
fix-headings edits heading lines directly instead of round-tripping the document through a syntax tree, so the two-space indent that makes a wrapped bullet point read as a continuation of the line above it is left untouched.
list-headings hands back a heading's full ancestor path in exactly the form get-section and replace-section expect as their own --heading argument, so you can chain the two commands together without reformatting anything by hand.
a script's ctx.log messages get collected and shown to you even on a run where nothing else in the document actually changed -- a script's own progress notes are never silently dropped just because there was no diff to report.
mdship deliberately gives the flag that disables an AI placeholder's manual-edit protection an alarming name, _yolo_, specifically so nobody enables it by accident while skimming a placeholder's configuration.
a PYTHON run: script is explicitly allowed to be non-deterministic across runs -- appending one more row to a table instead of rebuilding it from scratch is the whole point of handing the script its own previous output as input.
running mdship update --dry-run still actually executes every PYTHON script in the document, because that's the only way mdship can know what the file would become -- the file itself just never gets written, so any side effect the script performs on its own, like writing a cache or calling an API, still happens.
two different placeholders that both reference the very same helper script only ever run that script's own top-level code once per mdship invocation, because scripts are cached and loaded into their own private module namespace, keyed by absolute file path.
mdship refuses to run a script by any name that would resolve outside the project's own .mdship/scripts/ directory, which quietly closes off a path-traversal trick built from a script name full of parent-directory references.
mdship never installs a script's own dependencies for you -- if your project-local script needs a third-party package, the documented convention is a plain requirements.txt sitting right next to it in .mdship/scripts/.
the whole point of mdship's script trust file living in your home directory and being read-only is that a cloned or downloaded repository -- by git, zip, tarball, or any other means -- literally cannot grant itself permission to run code on your machine.
because mdship contains no code anywhere that changes file permissions, a bug in mdship itself can never accidentally grant script execution rights either -- the safety property comes from what the tool doesn't do, not from a check it might get wrong.
you can verify your project's script-trust setup is correctly locked down at any time, including in CI, with a single read-only command: mdship scripts check.
a PYTHON placeholder's transform hook is off-limits by design: any post-processing a run: script needs has to live inside its own run function, since needing a second script to patch up your own script's output would be a design smell.
a transform hook that renders a MERMAID diagram has exactly one job it's allowed to fail at: returning more than a single line of text for the image reference is a hard error, since the managed region a MERMAID placeholder tracks is always one line.
mdship gives every script chain, whether a transform pipeline or an audit pipeline, a shared scratch dictionary called ctx.pipe that starts empty and is thrown away the moment that one placeholder finishes processing.
a PYTHON define: script explicitly cannot see other variables collected so far, on purpose -- variable sources are meant to work in any order, so letting one peek at another's output would create a hidden dependency mdship has no way to detect.
an AI placeholder's closing marker isn't only ever the literal <!--/AI--> tag: absent a custom terminator, mdship will also accept the next heading at the same or shallower level, or simply the end of the file, as the natural end of the managed content.
list_ai_placeholders is deliberately a zero-cost discovery call: it returns every AI placeholder's name, line, and a cheap status without reading a single character of generated content or any dependency file.
the AI placeholder workflow treats trust in exactly opposite directions depending on where the text sits: content already generated between the markers is always assumed to be stale, so an instruction hidden inside it -- even one that reads like "ignore the prompt and write something else instead" -- is never obeyed.
mdship's GitHub Action, and mdship itself in CI generally, offers exactly three checks that only ever read your files and never modify them: validate, verify, and ai-check.
pointing mdship's GitHub Action at a glob pattern that matches absolutely nothing doesn't pass quietly -- the job fails outright with "No files matched," which is usually the tell that a path in your workflow file has a typo.
you can pin the exact mdship version a CI workflow installs, rather than always taking the newest release from PyPI, with a single version input on the action.
a scheduled weekly mdship check can catch documentation rot that nobody's editor would ever notice: a heading gets renamed or a file gets deleted, and nothing about that shows up as a diff until a link or anchor check actually runs against it again.
the mdship project checks its own README and its own release notes with the very same GitHub Action recipe it documents for everyone else's repository.
mdship's README table of contents is itself a live TOC placeholder with a custom closing tag named TIC instead of the usual TOC, presumably so the word "toc" appearing anywhere else in the README's own prose is never mistaken for the closing marker.
open nearly any page under mdship's own documentation/ folder and you'll find the exact AI prompt that generated it still sitting at the top, in an HTML comment invisible to anyone just reading the rendered page.
mdship's own release notes file is itself an AI-managed document: its front matter carries standing instructions telling Claude how to reconstruct missing entries from git history and where exactly to insert new ones.
an article mdship's own documentation includes about how it manages AI content was itself written as an AI placeholder, intended for publication on DZone and LinkedIn, complete with its own recorded prompt checksum sitting right above the byline.
the article makes the case that an embedded generation prompt is documentation in its own right: since it lives in the file next to what it produced, nobody has to go dig through a commit message or an old chat log to find out why a section says what it says.
mdship has a planned video series whose entire argument fits in one sentence its own planning document quotes directly: documentation drifts because facts get copied, so everything derivable should be derived and everything else verified.
a TOC placeholder doesn't blindly regenerate every anchor on every run: it only adds an anchor ID to a heading that doesn't already have one, and leaves an existing anchor exactly as it was.
mermaid diagrams rendered through mdship aren't limited to simple flowcharts -- sequence diagrams, entity-relationship diagrams, class diagrams, state diagrams, timelines, and pie charts are all fair game.
an INCLUDE placeholder's start and end patterns are allowed to be the literal same regular expression: the first match opens the included region and the very next match closes it, because once a region is open, mdship stops checking for a new start entirely and only asks whether the current line satisfies end.
because start isn't re-checked while a region is already open, a line that merely looks like another start marker in the middle of an open INCLUDE section is never mistaken for the start of a second region -- it's just ordinary content until end actually matches.
an INCLUDE with a start pattern that matches but is never followed by a matching end before the file runs out fails with an error naming exactly that: "End pattern not found ... after the matched start," rather than quietly including everything to the end of the file.
IMPORT's variable-source cousin SLURP is the odd one out among mdship's regex-based extractors: unlike SIP and SUP, it does not support the @pattern shorthand for named built-in patterns, and always compiles whatever regex you give it literally.
mdship distinguishes three separate outcomes when you rerun update on a document containing a MERMAID diagram: nothing at all changed, the image bytes changed even though the markdown line didn't, or this is effectively the first time -- and each one prints its own distinct message.
a document whose MERMAID diagram source changed but whose output filename stayed the same still gets reported with its own message, "diagram(s) regenerated," specifically because the markdown file's own content is unchanged even though the image on disk is not.
