# shared-album-rescue

Rescues iCloud **Shared Album** content into the real Photos library. Shared-album items
are a purgeable cache: viewing an album downloads thumbnails, not originals, and macOS
evicts the cached files over time. Content contributed by other people therefore mostly
exists *only* on Apple's servers — outside every backup. This tool inventories that gap,
stages every reachable copy, and imports the staged files as first-class library assets
(which then flow into iCloud Photos and normal backups).

Personal tool: default paths (live library on SecondLifeSSD, backup on Alexandria) are
baked in, in the same spirit as BackupManager's `BackupConfiguration`. Override with
`--library` / `--backup-library` / `--state`.

## Commands

| Command | What it does | Touches |
|---|---|---|
| `scan` | Per-album inventory: mine vs others, local, in-backup, staged, imported, cloud-only. Writes `state/scan.json`. | nothing (read-only) |
| `rescue` | Copies every reachable shared file (live cache + old backup, joined by cloud GUID) into `state/staging/`. | staging dir |
| `download` | Fetches cloud-only items from Apple's servers via PhotoKit into staging. | staging dir |
| `import` | Imports staged files into Photos, into `SA – <album>` albums, with dedup + ledger. | **Photos library** |
| `archive-comments` | Dumps shared-album comments/likes/captions to `state/comments-archive.json`. | nothing (read-only) |
| `verify` | Exits non-zero while any others' asset is still cloud-only. | nothing (read-only) |

Intended sequence:

```bash
./Scripts/build-app.sh        # builds release AND wraps it in SharedAlbumRescue.app
BIN=./SharedAlbumRescue.app/Contents/MacOS/shared-album-rescue

$BIN scan                     # inventory (safe, run anytime)
$BIN rescue --dry-run         # see the staging plan
$BIN rescue                   # stage from live cache + Dec-2025 backup
$BIN archive-comments         # save the comments/likes archive
$BIN download --limit 20      # first PhotoKit run: approve the “SharedAlbumRescue” Photos prompt
$BIN download                 # fetch everything still cloud-only
$BIN import --dry-run         # see the import plan
$BIN import --limit 20        # first supervised import
$BIN import                   # the rest
$BIN verify                   # should now exit 0
```

The database-only commands (`scan`, `rescue`, `archive-comments`, `verify`) also run fine
as the bare `.build/release/shared-album-rescue`. The PhotoKit commands (`download`,
`import`) must run through the `.app` wrapper: photolibraryd refuses XPC connections from
bundle-less binaries with endless `NSCocoaErrorDomain Code=4097` CoreData retries and
never shows the permission prompt.

## Safety model

- The live `Photos.sqlite` is **never opened directly** — the sqlite trio is copied to a
  temp dir first and opened read-only there.
- `scan` / `verify` / `archive-comments` / `rescue --dry-run` write nothing outside `state/`.
- Every asset is tracked by its **cloud GUID** (`ZCLOUDASSETGUID`) — the only identity that
  survives Photos migrations (local filenames were wholesale re-keyed by the ~Jan 2026
  migration). The import ledger (`state/imported-ledger.json`) makes `import` idempotent.
- Dedup layers: (1) ledger by GUID, (2) skip items whose original filename + capture
  second already exist in the library (disable with `--force`), (3) your own
  contributions are excluded by default (`--include-mine` to override) since their
  full-res originals are already library assets, and (4) Photos → Utilities → Duplicates
  for any near-dupe stragglers after import.

## Status / caveats

- `scan`, `rescue`, `archive-comments`, `verify`: exercised against the real library.
- `download`, `import`: **written but not yet run end-to-end** — run them via
  `SharedAlbumRescue.app` (see above), approve the Photos prompt, and start with
  `--limit 20`, eyeballing the result before going wide. `import` mutates the library.
- The ad-hoc app signature changes on every rebuild, so macOS re-asks the Photos
  permission question after each `./Scripts/build-app.sh`. Approve once per build.

## Troubleshooting

- **Endless `CoreData: XPC … Code=4097` retries, no prompt** — you ran a PhotoKit
  command through a binary without bundle identity. Use
  `./SharedAlbumRescue.app/Contents/MacOS/shared-album-rescue`, rebuilt by
  `./Scripts/build-app.sh`.
- **“Photos access not granted”** — System Settings → Privacy & Security → Photos →
  enable SharedAlbumRescue (re-grant after rebuilds).
- **“PhotoKit returned zero cloud-shared albums”** — Photos → Settings → iCloud →
  make sure “Shared Albums” is on.
- **Some assets report “no PhotoKit match”** — the album was deleted/left since the
  scan, or Photos hasn't synced it on this Mac; open Photos and check the sidebar.
- Shared copies are what Apple stores: ~2048px-class photos, 720p videos, others' GPS
  mostly stripped. True originals only exist with the original contributors.
- Imported items upload to iCloud Photos and count against its quota (expect roughly
  10–20 GB for the current backlog).
- Schema assumptions are pinned to Photos schema 5001 (macOS 26) and documented in
  `PhotosDB.swift`; a future macOS migration may need query updates.
- Follow-ups worth building: keyword/caption provenance via AppleScript (PhotoKit cannot
  set keywords), and the same pipeline for `scopes/syndication` ("Shared with You").
