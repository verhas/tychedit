# Tychedit 1.0.3

## Added

- Commit from the editor. A new **Commit to Git** toolbar button, and
  File ▸ Commit… (⌥⌘K), commit the file being edited when it lives in a
  git repository; both are disabled otherwise. A window asks for the
  commit message and offers **Commit**, **Commit + Push** and **Cancel**.
  Only the edited file is committed, whatever else is staged, and an
  unsaved file is saved first. Git's answer, or its error, is shown when
  it finishes. The button can be shown, hidden, moved and given another
  icon in Settings ▸ Toolbar.
- The preview shows what changed since the last commit, as the gutter
  does: text in blocks that were modified is blue, and text in blocks
  that were added is green, in both light and dark appearance.

## Changed

- `build.sh` gained `help` and `publish`, and `dmg` now refuses to package
  a version that has no matching release notes.
