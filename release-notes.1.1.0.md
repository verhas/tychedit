# Tychedit 1.1.0

## Added

- Support for mdship's `number:` front-matter key, which makes
  `mdship update` number (or unnumber) the headings on every run. The key
  is checked as you type, with mdship's own error messages: a value other
  than true, false or a mapping, an unknown option, a style other than
  period, space or parenthesis, or an option that is not true/false.
  Tychedit also says before you run the update when mdship would stop:
  `skip-title` with more than one h1, or numbering that would change a
  heading inside generated content without `generated: true` (or inside
  generated content that was edited by hand). Completion offers `number`,
  its options `style`, `skip-title`, `generated` and `post-process`, and
  their values. Needs mdship 1.4.0 or later.
- Tips at startup. A "Did You Know?" window shows one tip about mdship or
  Tychedit when the app starts; **Next** steps through the rest. Turn it
  off in the window itself or in Settings ▸ Editing, and bring it back at
  any time with Help ▸ Tips….
- Update checking, off unless you turn it on. With Settings ▸ Editing ▸
  "Check for updates at startup", Tychedit asks GitHub at most once a day
  whether a newer release exists; Tychedit ▸ Check for Updates… looks
  whenever you ask. Nothing is downloaded without a yes: **Download and
  Install** saves the disk image to your Downloads folder, opens it ready
  to drag into Applications, and quits Tychedit after asking about any
  unsaved changes.
