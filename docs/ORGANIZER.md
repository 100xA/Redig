# Local Mac organizer

Redig extends Abdur Rahim's [DigUp](https://github.com/ARahim3/DigUp) with local project collections and reversible
filing. It uses the existing Swift engine, EmbeddingGemma runtime and index; there is no separate AI server or account.
The original project and dependency credits remain in the README, license and acknowledgements.

## Start

1. Build this fork and open the Mac app.
2. Choose **Organize Files…** in the menu bar, or **Settings → Organizer**.
3. Click **Use Downloads, Desktop & Documents**, or choose other folders. Allow macOS folder access when prompted.
   These folders are also added to search; existing search exclusions and excluded extensions still apply.
4. Let the local index catch up. Collections appear automatically as supported files finish indexing. The existing
   model downloads once if it is missing; file contents are never sent to a service.
5. Expand a project to inspect its files and destination. **Assign…** corrects a match; **Rename…** changes the
   collection name. Neither action moves files. **File** moves a selected file to the displayed project folder.
6. Optionally turn on **File strong matches automatically**. This switch is separate from grouping and starts off.

The existing **General → Open at login** setting keeps the menu bar app available after signing in. The app must be
running for new grouping and filing work. Quitting stops it; collections and history remain on disk.

## Grouping and automatic filing

Existing project folders provide initial project collections. Related loose files are compared with their pooled
embeddings, including across Downloads, Desktop and Documents. Related loose files can also form new virtual
collections. Their proposed filing destination is a project folder under `Redig Organized` in a selected root.
New collections remain virtual until you file a member yourself. Collection names are derived locally from folder
and file names and can be edited.

Automatic filing requires all of the following:

- The source is directly inside an enabled organizer root, fully downloaded and completely indexed.
- The file has not been modified for at least 60 seconds, and its size, modification time, inode and device still
  match the indexed version.
- It has a strong semantic match to an existing project with at least two embedded supporting files. The initial
  thresholds are a cosine score of at least 0.90 and a lead of at least 0.08 over the next project. These are
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

## Undo and recovery

**Move history → Undo** restores a file to its recorded original path. Older and newer history pages remain available
after app restarts. Undo refuses to overwrite an occupied original path or restore a file that has been modified or
replaced since its move. If a folder was removed, add it again before undoing a move involving it. Undo marks the
original path as excluded from automatic refiling; you can still file it explicitly.

The move journal records an intent durably before touching a file. On macOS it coordinates moves with file presenters
and uses an exclusive rename, so a filename collision is never overwritten. A move across volumes copies and verifies
the bytes and file versions before removing the source. Symlinks, bundle contents, directories and cloud placeholders
are refused.

After an interrupted operation, opening the journal checks the recorded paths and identities. A completed move or
undo is recognized; an ambiguous operation is shown as failed for inspection. Recovery does not delete, move or choose
between ambiguous copies. Move history is independent of the disposable grouping cache.

## Implementation and validation

- SwiftUI/AppKit exposes setup, virtual collections, review, manual filing and paginated undo history.
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

Run `bash scripts/test-kit.sh` for model-free grouping, move/recovery and full filing-policy integration regressions.
Tests use synthetic vectors and temporary files; they do not read or organize personal Downloads, Desktop or Documents.
They cover cross-root matching, stable project identities, vector-cache reuse, stale and replaced files, exclusions,
collisions, durable undo, suppression after undo, interrupted operations and queued-policy revocation.

These checks validate deterministic behavior and file-operation guards. They do not measure the pretrained model's
project-grouping accuracy on a real personal library, and the copy fallback has not been exercised on a second physical
volume. Review virtual collections first to assess how the local model matches your files.
