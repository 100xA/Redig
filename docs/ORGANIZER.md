# Local Mac organizer

Redig extends Abdur Rahim's [DigUp](https://github.com/ARahim3/DigUp) with local project collections and reversible
filing. It uses the existing Swift engine, EmbeddingGemma runtime and index; there is no separate AI server or account.
The original project and dependency credits remain in the README, license and acknowledgements.

## Start

1. Build this fork and open the Mac app.
2. Press **⇧⌘Space**, type **`>auto on`** and press Return. With no organizer folders selected, this starts with
   Downloads. Or choose **Settings → Organizer → Organize Downloads Automatically**.
3. Drop supported files directly into Downloads. You can also choose **Use Downloads, Desktop & Documents** or other
   folders in Organizer. Allow macOS folder access when prompted. These folders are also added to search; existing
   search exclusions and excluded extensions still apply.
4. Let the local index catch up. Collections appear automatically as supported files finish indexing. The existing
   model downloads once if it is missing; file contents are never sent to a service.
5. Expand a project to inspect its files and destination. **Assign…** corrects a match; **Rename…** changes the
   collection name. Neither action moves files. **File** moves a selected file to the displayed project folder.
6. **File strong matches automatically** controls ongoing filing. **Create project folders automatically** is on by
   default and allows coherent new groups to create their own destinations. Both are enabled by the Downloads action.

The existing **General → Open at login** setting keeps the menu bar app available after signing in. The app must be
running for new grouping and filing work. Quitting stops it; collections and history remain on disk.

## Grouping and automatic filing

Existing project folders provide initial project collections. Related loose files are compared with their pooled
embeddings, including across Downloads, Desktop and Documents. Related loose files can also form new collections.
Their filing destination is a project folder under `Redig Organized` in a selected root. With folder creation enabled,
strong new groups of at least two fully indexed related files can create that folder and file their members without
an existing project or manual approval. Collection names are derived locally from folder and file names and can be
edited. Weak, ambiguous, filename-only and singleton matches stay for review.

Automatic filing requires all of the following:

- The source is directly inside an enabled organizer root, fully downloaded and completely indexed.
- The file has not been modified for at least 60 seconds, and its size, modification time, inode and device still
  match the indexed version.
- It has a strong semantic match to a supported project, or belongs to a coherent new group with at least two
  completed files. New groups require another completed member with strong pairwise similarity; every match is
  checked against competing projects. The initial thresholds are a cosine score of at least 0.90 and a lead of at
  least 0.08 over the next project. These are
  conservative heuristics, not calibrated probabilities; inspect the collections before enabling automatic filing.
- Both locations are inside the enabled roots and outside excluded folders. The destination filename is free.
- Indexing is not paused or outside its scheduled hours, and the configured roots are available and readable.

Filing runs in small batches on a utility queue. Files already inside project folders are not automatically
reshuffled. Filename-only fallback matches and ambiguous matches require review. The organizer supports Redig's
indexed documents, PDFs, pictures, screenshots, audio and video; unsupported archives/installers and excluded code
projects are outside this version's scope. It does not create Finder tags or rewrite document contents.

Existing `DigUp Organized` folders and filing destinations remain valid after renaming to Redig. The existing
DigUp support directory and settings identifiers are retained to reuse models, indexes and undo history.

Removing a folder from Organizer stops organizing it; it remains searchable until removed in **Settings → Folders**.
Removing a search root or adding an exclusion also revokes future organizer operations in that scope. Turning off
grouping stops automatic filing while preserving collections and history.

## Search bar commands

Both the hotkey panel and the full search window accept commands beginning with `>`. The `>` button in each bar opens
the command list. Use ↑ ↓ to choose, Tab to complete, Return to run, and Escape to return to file search. Commands are
parsed locally and never sent to an embedding model or shell. Typing, completing or selecting a command does not run it.

| Command | Action |
| --- | --- |
| `>help` or `>` | Show the command list. |
| `>auto on` / `>auto off` | Enable or stop ongoing filing. With no watched folders, `on` starts with Downloads. |
| `>folders on` / `>folders off` | Allow or stop creating new project folders during automatic or one-shot sorting. |
| `>preview` | Refresh groups without filing; show strong matches in the palette. |
| `>sort` | File ready strong matches once, leaving the saved automatic-filing switch unchanged. |
| `>projects` / `>projects client` | Browse projects, optionally filtering by name. |
| `>file "Client Alpha"` | Explicitly file up to ten ready members of that project. Choose a project row to disambiguate duplicate names. |
| `>review` | Review uncertain files and assign a project in the palette. Assignment changes the collection only. |
| `>history` | Show the latest move history and individual Undo buttons. |
| `>undo` / `>undo 42` | Restore the most recent undoable move, or a particular move by its displayed number. |
| `>pause` / `>resume` | Pause or resume indexing and automatic filing. |
| `>organize` / `>settings` | Open Organizer or general settings. |

`>sort` and ongoing filing use the same confidence, completed-index, settling, scope, collision and version checks.
Preview, one-shot sorting and explicit project filing preserve the saved grouping and automatic-filing switches;
they can use selected folders even when ongoing grouping is off. With no selected scope, preview and sort prepare
Downloads for indexing without activating ongoing automation.
Explicit project filing uses the selected project and the guarded move journal; it can create a chosen destination
even when automatic folder creation is off. Each completed file move has its own Undo entry. For a large explicit
project, run the command again for the next batch. To hold all files in place while inspecting a preview, use
`>auto off` first. Changing the watched-folder policy cancels queued work; an atomic move already in progress finishes
and stays in history.

## Undo and recovery

**Move history → Undo** restores a file to its recorded original path. Older and newer history pages remain available
after app restarts. Undo refuses to overwrite an occupied original path or restore a file that has been modified or
replaced since its move. If a folder was removed, add it again before undoing a move involving it. Undo marks the
original path as excluded from automatic refiling; you can still file it explicitly.
Undo restores files; newly created empty project folders remain available for reuse.

The move journal records an intent durably before touching a file. On macOS it coordinates moves with file presenters
and uses an exclusive rename, so a filename collision is never overwritten. A move across volumes copies and verifies
the bytes and file versions before removing the source. Symlinks, bundle contents, directories and cloud placeholders
are refused.

After an interrupted operation, opening the journal checks the recorded paths and identities. A completed move or
undo is recognized; an ambiguous operation is shown as failed for inspection. Recovery does not delete, move or choose
between ambiguous copies. Move history is independent of the disposable grouping cache.

## Implementation and validation

- SwiftUI/AppKit exposes Downloads setup, project collections, review, explicit filing, paginated undo history and a
  shared keyboard command palette in both search interfaces.
- The existing FSEvents/index pipeline supplies committed updates. The controller coalesces refreshes and also checks
  every 30 seconds for files that have become old enough to file. It respects pause/schedule and scope changes.
- SQLite in the configured index directory stores `organizer.noindex/organizer.sqlite`. Separate project and move
  tables share WAL mode; move intents use full synchronous durability. Connections stay on one serial utility queue.
- Grouping caches one pooled vector per file, reading at most 16 existing segment vectors when its vector generation
  changes. An unchanged refresh or metadata-only update does not reread vector blobs. New-cluster candidate work is
  bounded rather than comparing every loose file with every other file. No second model is loaded.
- Model-source and index-identity changes invalidate cached vectors. Manual choices and project names persist;
  incompatible grouping snapshots can be regenerated without deleting the move journal.
- Worker configuration revisions revoke queued automation when folder policy or pause state changes. An atomic
  operation already in progress finishes safely and its changed paths are sent back to the indexer.

Run `bash scripts/test-kit.sh` for model-free grouping, command parsing, move/recovery and filing-policy regressions.
Run `bash scripts/test-organizer-commands.sh` for the actual native palette, command dispatcher and controller with a
temporary indexed library and record-only app host. It tests that typing/completion have no side effects, commands
persist preferences, preview does not file, one-shot sorting creates folders, and Undo restores files.
Tests use synthetic vectors and temporary files; they do not read or organize personal Downloads, Desktop or Documents.
They cover cross-root matching, stable project identities, vector-cache reuse, stale and replaced files, exclusions,
collisions, durable undo, suppression after undo, interrupted operations and queued-policy revocation.

These checks validate deterministic behavior and file-operation guards. They do not measure the pretrained model's
project-grouping accuracy on a real personal library, and the copy fallback has not been exercised on a second physical
volume. Review virtual collections first to assess how the local model matches your files.
