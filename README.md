# disk-size-growth-mon

A small Windows desktop tool that answers one question: **what has been eating my disk since last time?**

It is not a monitor that runs in the background. You launch it (say, every morning), press **Scan**, and
when it finishes you get a table of the folders that grew the most since the previous scan of that drive.
Every scan is kept in a SQLite database, so the comparison is always "this scan vs. the previous scan of
the same drive".

Think `du` on a schedule you control, with the diff already computed.

---

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Install and run](#install-and-run)
- [The window](#the-window)
- [Configuration](#configuration)
- [How scanning works](#how-scanning-works)
- [How the growth report works](#how-the-growth-report-works)
- [Database](#database)
- [Building from source](#building-from-source)
- [Tests](#tests)
- [Design decisions](#design-decisions)
- [Known limitations](#known-limitations)
- [License](#license)

---

## What it does

- Walks an entire drive as **Administrator**, so protected system folders are measured too.
- Records the **recursive size** of every folder down to a configurable depth, above a configurable size.
- Stores each scan in SQLite and, the moment a scan finishes, **pre-computes** the growth report against
  the previous scan of that drive.
- Shows a scan history; picking any past scan renders its report instantly (nothing is recomputed).
- Pause / stop mid-scan, a live log of what is being walked, single-instance enforcement, and a clean
  shutdown that leaves nothing running.

---

## Requirements

| | |
|---|---|
| OS | Windows 10 / 11 (x64). Windows 7+ is declared in the manifest but untested. |
| Runtime | **None.** The published `.exe` is self-contained (~64 MB). |
| Privileges | Elevation is **required** — the manifest sets `requestedExecutionLevel = requireAdministrator`, so Windows shows a UAC prompt on every launch. Without it, protected folders would silently measure as empty. |
| To build | .NET 8 SDK. |

---

## Install and run

Grab `DiskSizeGrowthMon.exe` (or build it — see below) and drop it in a folder you own, e.g.
`C:\Tools\disk-size-growth-mon\`. It is portable: everything it creates lives next to the executable.

```
DiskSizeGrowthMon.exe     the app
config.json               created on first run with defaults
diskgrowth.db             SQLite database (plus -wal / -shm while running)
```

> Put it somewhere writable. `C:\Program Files` works because the app is elevated, but a plain folder
> keeps the database easy to find, back up, and delete.

**Running it every morning.** The app deliberately does not scan on its own. If you want it waiting for
you at login, add a Task Scheduler entry:

```powershell
$action  = New-ScheduledTaskAction  -Execute 'C:\Tools\disk-size-growth-mon\DiskSizeGrowthMon.exe'
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName 'Disk Growth Monitor' -Action $action -Trigger $trigger `
                       -RunLevel Highest -Description 'Opens the disk growth monitor at logon.'
```

`-RunLevel Highest` makes the scheduler launch it elevated without a UAC prompt. It still only opens the
window — you press **Scan**.

---

## The window

```
┌─ Scan ─────────────────────────────────────────────────────────────────────┐
│ ┌──────────────────────────────┐                                           │
│ │ C:  Windows-SSD   12.3 GB …  │    ┌──────────┐   ┌──────────┐            │
│ │ D:  data          56.1 GB …  │    │   Scan   │   │   Stop   │            │
│ │ E:  storage       36.9 GB …  │    └──────────┘   └──────────┘            │
│ └──────────────────────────────┘                                           │
│ ┌────────────────────────────────────────────────────────────────────────┐ │
│ │ C:\Users\me\AppData\Local\Docker                                       │ │
│ │ C:\Users\me\AppData\Local\Temp                    ← 7-line live log,   │ │
│ │ C:\Users\me\AppData\Local\Packages                  auto-scrolling     │ │
│ └────────────────────────────────────────────────────────────────────────┘ │
│ Scanning C:   elapsed 00:02:14   folders 184,203   files 1,104,558   …     │
└────────────────────────────────────────────────────────────────────────────┘
┌─ Growth report ────────────────────────────────────────────────────────────┐
│ 2026-08-10 09:35 C: │ C: • 2026-08-10 09:35 vs 2026-08-09 08:12 • 41 …     │
│ 2026-08-09 08:12 C: │ ┌───┬──────────────────────┬─────────┬────────┬────┐ │
│ 2026-08-08 09:02 D: │ │ # │ Folder               │ Last GB │ Now GB │ +GB│ │
│ 2026-08-08 08:44 C: │ │ 1 │ C:\…\Local\Docker    │    23.9 │   37.4 │13.5│ │
│                     │ │ 2 │ C:\…\Local\Temp      │     6.3 │    9.1 │ 2.8│ │
│                     │ └───┴──────────────────────┴─────────┴────────┴────┘ │
└────────────────────────────────────────────────────────────────────────────┘
```

**Scan panel**

- The drive list shows every ready **fixed or removable** drive with its label and free/total space.
- **Scan** starts a scan. While one is running the same button becomes **Pause**, then **Resume**.
- **Stop** is disabled until a scan starts. Stopping **discards** the scan (see below).
- The log keeps the last `LogMaxLines` lines; when it overflows it is trimmed back to `LogKeepLines`,
  so it never grows without bound. Every folder at or above `MaxDepth` gets a line; below that the log
  is sampled at ~7 lines/second, because deep trees produce tens of thousands of folders per second.
- The status line shows elapsed time, folder/file counts, bytes seen, and unreadable-folder count.

**Report panel**

- History is sorted newest-first and mixes drives; each entry reads `2026-08-10 09:35 C: (21.4GB)`,
  where the number in parentheses is the drive's free space when that scan started. Scans recorded
  before that was captured show no parentheses — the value cannot be reconstructed after the fact.
- A scan in progress is **not** in the list. It is added at the top and auto-selected when it completes.
- The table is fixed-sort — largest growth first — and column headers are deliberately not clickable.
- At most `MaxReportRows` (default 300) rows are stored and shown.
- Growth cells are tinted: amber from 1 GB, red from 5 GB.

**Closing.** If a scan is running, closing asks for confirmation, then cancels the scan, waits for the
walk thread to unwind, and only then exits — no orphaned threads or half-written database.

**Single instance.** A second launch shows an error and exits immediately. The lock is a `Global\` named
mutex, so it holds across user sessions.

---

## Configuration

`config.json` sits next to the executable and is created with defaults on first run. It is read **once at
startup** — restart the app after editing.

| Key | Default | Meaning |
|---|---|---|
| `MaxDepth` | `6` | Deepest level **persisted**. The drive root is depth 0, so `C:\Users\me\AppData\Local\Temp\Foo` is depth 6. Anything deeper is still measured, but its bytes roll up into its depth-6 ancestor. |
| `MinFolderSizeGB` | `0.5` | Folders whose recursive size is below this are not persisted. |
| `MaxReportRows` | `300` | Cap on report rows stored and displayed. |
| `LogMaxLines` | `1000` | Live log is trimmed once it passes this. |
| `LogKeepLines` | `500` | How many lines survive a trim. Must be `>= 10` and `< LogMaxLines`. |
| `DatabasePath` | `"diskgrowth.db"` | Relative paths resolve against the executable's folder; absolute paths are used as-is. |
| `ExcludedPaths` | `[]` | Full paths skipped entirely, along with everything under them. Case-insensitive. e.g. `["D:\\Backups", "C:\\VMs"]`. |
| `RetainScansPerDrive` | `30` | After each scan, older scans of that drive beyond this count are deleted. `0` keeps everything. |

Out-of-range values are clamped and reported in a warning dialog at startup; a malformed file falls back
to defaults and is left untouched so you can fix it.

### Tuning the two that matter

`MaxDepth` and `MinFolderSizeGB` trade precision against database size. They do **not** change scan
duration much — the whole tree is walked either way.

| Setting | Rows per C: scan | Good for |
|---|---|---|
| depth 6, 0.5 GB (default) | a few hundred | "which of my big folders is creeping up" |
| depth 8, 0.1 GB | a few thousand | pinning growth down to a specific cache directory |
| depth 12, 0.01 GB | tens of thousands | forensic; expect a database in the hundreds of MB after a month |

---

## How scanning works

The walk lives in [`DiskScanner.cs`](src/DiskSizeGrowthMon/DiskScanner.cs).

- **Iterative, not recursive.** An explicit `Stack<Frame>` drives a post-order traversal. Real trees get
  deep enough to overflow the call stack, and an explicit stack also guarantees exactly one open
  directory handle per level.
- **Enumeration** uses `System.IO.Enumeration.FileSystemEnumerable<T>`, which reads name, attributes and
  length straight out of the native `FILE_FULL_DIR_INFORMATION` record — no second `stat` call per file.
  `AttributesToSkip = 0` so hidden and system files count.
- **Sizes are recursive**: a folder's size is its own files plus every descendant. That is what TreeSize
  and `du` show by default. The consequence is that a single growing leaf also makes all of its ancestors
  appear in the report — the report reads top-down, and the deepest row is the real culprit.
- **Reparse points are skipped.** Junctions and symlinks (`C:\Documents and Settings`, container layer
  links, and so on) point at bytes owned by some other folder. Following them would double-count at best
  and loop forever at worst. The smoke test asserts this with a junction pointing at its own parent.
- **Inaccessible folders are skipped, not fatal.** `IgnoreInaccessible = true` handles ACL denials; the
  remainder (bad reparse targets, device errors) is caught per directory, logged as `[skipped] …`, and
  counted in the status line. Even elevated, a few paths such as `System Volume Information` may refuse.
- **Sizes are logical, not on-disk.** Compressed, sparse and deduplicated files report their logical
  length, so totals can exceed what the volume actually holds. Growth deltas remain meaningful.
- **Hard-linked files are counted once per path they appear under**, so `WinSxS` looks larger than the
  space it truly costs. This matches TreeSize's default behaviour.

**Pause** is a `ManualResetEventSlim` gate checked once per entry — a single volatile read when running,
so it costs nothing. **Stop** is a `CancellationToken` checked in the same place; a paused scan is resumed
first so it can observe the cancellation.

### Stopped scans are discarded

If you stop a scan, nothing is written. A partial walk produces folder sizes that are simply wrong (a
folder whose children were not all visited reports too little), and storing them would corrupt not just
that report but the *next* one too, since it would become the baseline. The log says so explicitly.

---

## How the growth report works

When a scan finishes, one SQL statement builds and stores the whole report inside the same transaction
that saves the folder sizes:

```sql
INSERT INTO growth_report (scan_id, rank, path, prev_bytes, curr_bytes, growth_bytes)
SELECT $scan,
       ROW_NUMBER() OVER (ORDER BY growth_bytes DESC, curr_bytes DESC, path ASC),
       path, prev_bytes, curr_bytes, growth_bytes
FROM (
    SELECT c.path,
           COALESCE(p.size_bytes, 0)                AS prev_bytes,
           c.size_bytes                             AS curr_bytes,
           c.size_bytes - COALESCE(p.size_bytes, 0) AS growth_bytes
    FROM folder_sizes c
    LEFT JOIN folder_sizes p ON p.scan_id = $prev AND p.path = c.path
    WHERE c.scan_id = $scan
)
WHERE growth_bytes > 0
ORDER BY growth_bytes DESC, curr_bytes DESC, path ASC
LIMIT $limit;
```

Which gives these rules:

- **Comparison is against the previous scan of the same drive**, not the previous scan overall.
- **New folders compare against 0**, so a freshly created 20 GB cache shows up at its full size. That is
  usually exactly what you want to see.
- **Shrunk and unchanged folders are omitted.** This is a growth report; `growth_bytes > 0` is the filter.
- **Sizes are GiB** (1024³ bytes) rounded to one decimal, labelled "GB" as everyone does.
- **The report is stored, not derived.** Selecting a scan in the history is a single indexed read, so it
  is instant even for scans whose raw folder rows have since been pruned by `RetainScansPerDrive`.

### Two caveats worth knowing

1. **The first scan of a drive is a baseline, not a report.** With no previous scan every folder compares
   against 0, so the "report" is just a size ranking. The header says so in capitals. The second scan is
   the first useful one.

2. **`MinFolderSizeGB` can inflate a delta.** A folder that sat at 0.4 GB (below the threshold, so not
   stored) and is now 0.6 GB appears as `0.0 → 0.6, +0.6` rather than `+0.2`. The tool over-reports
   slightly at the threshold boundary rather than hiding the folder. Lower `MinFolderSizeGB` if that
   bothers you.

---

## Database

SQLite via [`Microsoft.Data.Sqlite`](https://learn.microsoft.com/dotnet/standard/data/sqlite/), WAL
journaling, `synchronous = NORMAL`, foreign keys on. One connection for the process lifetime, every
public method guarded by a lock, because the scan thread writes while the UI thread reads.

```sql
CREATE TABLE scans (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    drive          TEXT    NOT NULL,   -- 'C:'
    started_utc    TEXT    NOT NULL,   -- ISO-8601, the sort key
    started_local  TEXT    NOT NULL,   -- 'yyyy-MM-dd HH:mm:ss', what you see
    prev_scan_id   INTEGER NULL REFERENCES scans(id) ON DELETE SET NULL,
    max_depth      INTEGER NOT NULL,   -- config in force for this scan
    min_size_bytes INTEGER NOT NULL,
    folder_count   INTEGER NOT NULL,
    total_bytes    INTEGER NOT NULL,
    duration_ms    INTEGER NOT NULL
);

CREATE TABLE folder_sizes (            -- one row per (scan, folder)
    scan_id    INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
    path       TEXT    NOT NULL,
    depth      INTEGER NOT NULL,
    size_bytes INTEGER NOT NULL,       -- recursive
    PRIMARY KEY (scan_id, path)
) WITHOUT ROWID;

CREATE TABLE growth_report (           -- pre-computed at scan completion
    scan_id      INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
    rank         INTEGER NOT NULL,
    path         TEXT    NOT NULL,
    prev_bytes   INTEGER NOT NULL,
    curr_bytes   INTEGER NOT NULL,
    growth_bytes INTEGER NOT NULL,
    PRIMARY KEY (scan_id, rank)
) WITHOUT ROWID;
```

`WITHOUT ROWID` on the two wide tables keeps rows in the primary-key B-tree itself, which is both smaller
and faster here since every access is by that key.

### Poking at it yourself

The report the UI shows is deliberately narrow (one scan vs. the one before it). The database supports
more. For example, a folder's trend across every scan of C::

```sql
SELECT s.started_local, f.size_bytes / 1073741824.0 AS gb
FROM   folder_sizes f
JOIN   scans s ON s.id = f.scan_id
WHERE  s.drive = 'C:' AND f.path = 'C:\Users\me\AppData\Local\Docker'
ORDER  BY s.started_utc;
```

Or the folders that grew in *every* one of the last N scans — the "growing gradually" question, answered
across the whole history rather than a single step:

```sql
SELECT path, COUNT(*) AS times_grown, SUM(growth_bytes) / 1073741824.0 AS total_gb
FROM   growth_report r
JOIN   scans s ON s.id = r.scan_id
WHERE  s.drive = 'C:'
GROUP  BY path
HAVING times_grown >= 5
ORDER  BY total_gb DESC;
```

---

## Building from source

```powershell
git clone https://github.com/fatehiman/disk-size-growth-mon.git
cd disk-size-growth-mon
.\build.ps1
```

`build.ps1` runs the smoke tests and then publishes to `.\dist`. Under the hood:

```powershell
dotnet publish src\DiskSizeGrowthMon\DiskSizeGrowthMon.csproj `
    -c Release -r win-x64 --self-contained true -o dist
```

Publish settings live in the `.csproj`: `PublishSingleFile`, `IncludeNativeLibrariesForSelfExtract` (the
SQLite native library has to be extracted at runtime), and `EnableCompressionInSingleFile`. The result is
one ~64 MB `.exe` with no runtime prerequisite.

> The repo ships a `nuget.config` pinning nuget.org, because a machine with no configured package source
> fails to restore with `NU1100`.

### Project layout

```
src/DiskSizeGrowthMon/
    Program.cs           entry point, single-instance mutex, elevation check
    MainForm.cs          the entire UI, built in code (no designer file)
    DiskScanner.cs       the walk
    Database.cs          schema, persistence, report generation
    AppConfig.cs         config.json load / create / validate
    Models.cs            FolderSize, ReportRow, ScanSummary
    PauseController.cs   the pause gate
    app.manifest         requireAdministrator, longPathAware
tests/SmokeTests/        end-to-end assertions over the non-UI code
build.ps1
```

The UI is built in code rather than with a `.Designer.cs` file — it is one window with a fixed layout,
and a hand-written `TableLayoutPanel` tree diffs far better in git than designer-generated markup.

---

## Tests

```powershell
dotnet run --project tests\SmokeTests
```

Nineteen assertions over the parts that are worth being sure about, in ~2 seconds: the walk against a
synthetic tree (including a self-referencing junction), depth capping and roll-up, growth arithmetic,
new/shrunk/unchanged folder handling, rank ordering, history linkage, retention, and cancellation.
Exit code is non-zero if anything fails, so `build.ps1` refuses to publish a broken build.

There is no UI test framework here; the window is verified by rendering it offscreen during development.

---

## Design decisions

**Why SQLite?** It is the right answer for this shape of problem: a single-process desktop app, a few
hundred thousand rows, one writer, and queries that are all "give me rows for this scan id". It needs no
service, the whole history is one file you can copy or delete, and `Microsoft.Data.Sqlite` bundles the
native library so the published exe stays dependency-free. LiteDB would have been the other reasonable
pick, but the reporting here is relational — a join between two scans — and that is SQL's home ground.
A flat file (JSON/CSV per scan) would have worked at this size too, but pruning, indexed lookup, and the
report query all come free with SQLite.

**Why pre-compute the report?** Because you asked not to wait when clicking around the history, and
because it makes the report durable: `RetainScansPerDrive` can delete a scan's several hundred thousand
raw folder rows while its 300-row report survives.

**Why C# / WinForms?** Native Windows, a two-line manifest for elevation, direct access to the fastest
managed directory-enumeration API, and single-file self-contained publishing. WPF would have been prettier
and slower to write; C++ smaller and much slower to write; Python would have meant a bigger exe and a
noticeably slower walk.

**Why discard stopped scans?** See [above](#stopped-scans-are-discarded) — a partial walk is not just
incomplete, it is wrong, and it would poison the next comparison as well.

---

## Known limitations

- One drive per scan. Scanning C:, then D:, means two scans and two history entries.
- Sizes are logical, and hard-linked content is counted under each path it appears at.
- Config is read at startup only.
- The report compares consecutive scans. "Growing gradually over two weeks" needs a query against the
  database — there is one ready to paste [above](#poking-at-it-yourself).
- No CSV/HTML export from the UI yet.
- x64 only in the published artifact; `build.ps1 -Runtime win-arm64` produces an ARM64 build.

---

## License

MIT — see [LICENSE](LICENSE).
