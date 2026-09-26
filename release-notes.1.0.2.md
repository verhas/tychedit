# Tychedit 1.0.2

## Fixed

- Autosave no longer reports "Autosave failed: You do not have
  permission..." for saves that actually succeeded. The save path
  replaces a file with `FileManager.replaceItemAt`, which swaps the
  content first and only afterward tries to carry the original's
  permissions, extended attributes and creation date over to the
  replacement; a permission problem in that second step used to be
  reported as a failure even though the new content was already on disk.
  The save now trusts what is actually on disk over that error.
