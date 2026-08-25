using System.Globalization;
using Microsoft.Data.Sqlite;

namespace DiskSizeGrowthMon;

/// <summary>
/// SQLite store. One connection for the whole app lifetime, every public method guarded by
/// a lock — the scan thread writes at the end of a scan while the UI thread reads reports.
/// </summary>
public sealed class Database : IDisposable
{
    private readonly SqliteConnection _cn;
    private readonly object _gate = new();

    public string Path { get; }

    public Database(string path)
    {
        Path = path;
        string? dir = System.IO.Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        var csb = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Private,
            Pooling = false
        };

        _cn = new SqliteConnection(csb.ToString());
        _cn.Open();

        Exec("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous  = NORMAL;
            PRAGMA foreign_keys = ON;
            PRAGMA temp_store   = MEMORY;
            """);

        Migrate();
    }

    private void Migrate()
    {
        Exec(SchemaSql);

        // Databases written before free space was captured keep NULL here; the UI renders
        // those without the "(x GB)" suffix rather than inventing a number.
        AddColumnIfMissing("scans", "free_bytes", "INTEGER NULL");
        AddColumnIfMissing("scans", "drive_size_bytes", "INTEGER NULL");
    }

    private void AddColumnIfMissing(string table, string column, string decl)
    {
        using (var probe = _cn.CreateCommand())
        {
            probe.CommandText = $"SELECT COUNT(*) FROM pragma_table_info('{table}') WHERE name = $c;";
            probe.Parameters.AddWithValue("$c", column);
            if (Convert.ToInt64(probe.ExecuteScalar()!) > 0) return;
        }

        Exec($"ALTER TABLE {table} ADD COLUMN {column} {decl};");
    }

    private const string SchemaSql = """
        CREATE TABLE IF NOT EXISTS scans (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            drive          TEXT    NOT NULL,          -- 'C:'
            started_utc    TEXT    NOT NULL,          -- ISO-8601, sort key
            started_local   TEXT   NOT NULL,          -- 'yyyy-MM-dd HH:mm:ss', display
            prev_scan_id   INTEGER NULL REFERENCES scans(id) ON DELETE SET NULL,
            max_depth      INTEGER NOT NULL,
            min_size_bytes INTEGER NOT NULL,
            folder_count   INTEGER NOT NULL,
            total_bytes    INTEGER NOT NULL,
            duration_ms    INTEGER NOT NULL,
            free_bytes       INTEGER NULL,      -- drive free space when the scan started
            drive_size_bytes INTEGER NULL       -- drive capacity when the scan started
        );

        CREATE INDEX IF NOT EXISTS ix_scans_drive_time ON scans(drive, started_utc DESC);

        -- Recursive size of each persisted folder, one row per (scan, folder).
        CREATE TABLE IF NOT EXISTS folder_sizes (
            scan_id    INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
            path       TEXT    NOT NULL,
            depth      INTEGER NOT NULL,
            size_bytes INTEGER NOT NULL,
            PRIMARY KEY (scan_id, path)
        ) WITHOUT ROWID;

        -- Pre-computed at the end of each scan so selecting a scan renders instantly.
        CREATE TABLE IF NOT EXISTS growth_report (
            scan_id      INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
            rank         INTEGER NOT NULL,
            path         TEXT    NOT NULL,
            prev_bytes   INTEGER NOT NULL,
            curr_bytes   INTEGER NOT NULL,
            growth_bytes INTEGER NOT NULL,
            PRIMARY KEY (scan_id, rank)
        ) WITHOUT ROWID;
        """;

    /// <summary>
    /// Persists a finished scan and its growth report in one transaction. Partial scans are
    /// never written: their sizes would be wrong and would poison the next comparison.
    /// </summary>
    public long SaveScan(string drive, DateTime startedUtc, DateTime startedLocal, AppConfig cfg, ScanResult result,
                         long? freeBytes = null, long? driveSizeBytes = null)
    {
        lock (_gate)
        {
            using var tx = _cn.BeginTransaction();

            long? prevId = QueryLatestScanId(drive, tx);

            long scanId;
            using (var cmd = _cn.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = """
                    INSERT INTO scans (drive, started_utc, started_local, prev_scan_id,
                                       max_depth, min_size_bytes, folder_count, total_bytes, duration_ms,
                                       free_bytes, drive_size_bytes)
                    VALUES ($drive, $utc, $local, $prev, $depth, $min, $folders, $total, $ms,
                            $free, $capacity);
                    SELECT last_insert_rowid();
                    """;
                cmd.Parameters.AddWithValue("$drive", drive);
                cmd.Parameters.AddWithValue("$utc", startedUtc.ToString("O", CultureInfo.InvariantCulture));
                cmd.Parameters.AddWithValue("$local", startedLocal.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture));
                cmd.Parameters.AddWithValue("$prev", (object?)prevId ?? DBNull.Value);
                cmd.Parameters.AddWithValue("$depth", cfg.MaxDepth);
                cmd.Parameters.AddWithValue("$min", cfg.MinFolderSizeBytes);
                cmd.Parameters.AddWithValue("$folders", result.Folders.Count);
                cmd.Parameters.AddWithValue("$total", result.TotalBytes);
                cmd.Parameters.AddWithValue("$ms", (long)result.Elapsed.TotalMilliseconds);
                cmd.Parameters.AddWithValue("$free", (object?)freeBytes ?? DBNull.Value);
                cmd.Parameters.AddWithValue("$capacity", (object?)driveSizeBytes ?? DBNull.Value);
                scanId = (long)cmd.ExecuteScalar()!;
            }

            using (var ins = _cn.CreateCommand())
            {
                ins.Transaction = tx;
                ins.CommandText = "INSERT INTO folder_sizes (scan_id, path, depth, size_bytes) VALUES ($s, $p, $d, $b);";
                var pS = ins.Parameters.Add("$s", SqliteType.Integer);
                var pP = ins.Parameters.Add("$p", SqliteType.Text);
                var pD = ins.Parameters.Add("$d", SqliteType.Integer);
                var pB = ins.Parameters.Add("$b", SqliteType.Integer);
                pS.Value = scanId;
                foreach (var f in result.Folders)
                {
                    pP.Value = f.Path;
                    pD.Value = f.Depth;
                    pB.Value = f.SizeBytes;
                    ins.ExecuteNonQuery();
                }
            }

            BuildReport(scanId, prevId, cfg.MaxReportRows, tx);

            tx.Commit();
            return scanId;
        }
    }

    /// <summary>
    /// Ranks every folder of <paramref name="scanId"/> against the same path in the previous
    /// scan. Folders absent from the previous scan compare against 0, so a brand-new cache
    /// shows up at its full size. Shrinking folders are dropped — this is a growth report.
    /// </summary>
    private void BuildReport(long scanId, long? prevScanId, int maxRows, SqliteTransaction tx)
    {
        using var cmd = _cn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = """
            INSERT INTO growth_report (scan_id, rank, path, prev_bytes, curr_bytes, growth_bytes)
            SELECT $scan,
                   ROW_NUMBER() OVER (ORDER BY growth_bytes DESC, curr_bytes DESC, path ASC),
                   path, prev_bytes, curr_bytes, growth_bytes
            FROM (
                SELECT c.path                                    AS path,
                       COALESCE(p.size_bytes, 0)                 AS prev_bytes,
                       c.size_bytes                              AS curr_bytes,
                       c.size_bytes - COALESCE(p.size_bytes, 0)  AS growth_bytes
                FROM folder_sizes c
                LEFT JOIN folder_sizes p
                       ON p.scan_id = $prev AND p.path = c.path
                WHERE c.scan_id = $scan
            )
            WHERE growth_bytes > 0
            ORDER BY growth_bytes DESC, curr_bytes DESC, path ASC
            LIMIT $limit;
            """;
        cmd.Parameters.AddWithValue("$scan", scanId);
        cmd.Parameters.AddWithValue("$prev", prevScanId ?? -1L);
        cmd.Parameters.AddWithValue("$limit", maxRows);
        cmd.ExecuteNonQuery();
    }

    private long? QueryLatestScanId(string drive, SqliteTransaction? tx)
    {
        using var cmd = _cn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = "SELECT id FROM scans WHERE drive = $d ORDER BY started_utc DESC, id DESC LIMIT 1;";
        cmd.Parameters.AddWithValue("$d", drive);
        object? v = cmd.ExecuteScalar();
        return v is null or DBNull ? null : Convert.ToInt64(v);
    }

    public List<ScanSummary> GetScans()
    {
        lock (_gate)
        {
            var list = new List<ScanSummary>();
            using var cmd = _cn.CreateCommand();
            cmd.CommandText = """
                SELECT s.id, s.drive, s.started_local, s.prev_scan_id, p.started_local,
                       s.folder_count, s.total_bytes, s.max_depth, s.min_size_bytes, s.duration_ms,
                       s.free_bytes, s.drive_size_bytes
                FROM scans s
                LEFT JOIN scans p ON p.id = s.prev_scan_id
                ORDER BY s.started_utc DESC, s.id DESC;
                """;
            using var r = cmd.ExecuteReader();
            while (r.Read())
            {
                list.Add(new ScanSummary(
                    Id: r.GetInt64(0),
                    Drive: r.GetString(1),
                    StartedLocal: DateTime.ParseExact(r.GetString(2), "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),
                    PrevScanId: r.IsDBNull(3) ? null : r.GetInt64(3),
                    PrevStartedLocal: r.IsDBNull(4) ? null : DateTime.ParseExact(r.GetString(4), "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),
                    FolderCount: r.GetInt32(5),
                    TotalBytes: r.GetInt64(6),
                    MaxDepth: r.GetInt32(7),
                    MinSizeBytes: r.GetInt64(8),
                    DurationMs: r.GetInt32(9),
                    FreeBytes: r.IsDBNull(10) ? null : r.GetInt64(10),
                    DriveSizeBytes: r.IsDBNull(11) ? null : r.GetInt64(11)));
            }
            return list;
        }
    }

    public List<ReportRow> GetReport(long scanId)
    {
        lock (_gate)
        {
            var rows = new List<ReportRow>();
            using var cmd = _cn.CreateCommand();
            cmd.CommandText = """
                SELECT rank, path, prev_bytes, curr_bytes, growth_bytes
                FROM growth_report WHERE scan_id = $s ORDER BY rank;
                """;
            cmd.Parameters.AddWithValue("$s", scanId);
            using var r = cmd.ExecuteReader();
            while (r.Read())
                rows.Add(new ReportRow(r.GetInt32(0), r.GetString(1), r.GetInt64(2), r.GetInt64(3), r.GetInt64(4)));
            return rows;
        }
    }

    /// <summary>Drops scans older than the newest <paramref name="keep"/> for a drive. 0 disables pruning.</summary>
    public int PruneOldScans(string drive, int keep)
    {
        if (keep <= 0) return 0;
        lock (_gate)
        {
            using var cmd = _cn.CreateCommand();
            cmd.CommandText = """
                DELETE FROM scans WHERE id IN (
                    SELECT id FROM scans WHERE drive = $d
                    ORDER BY started_utc DESC, id DESC
                    LIMIT -1 OFFSET $keep
                );
                """;
            cmd.Parameters.AddWithValue("$d", drive);
            cmd.Parameters.AddWithValue("$keep", keep);
            return cmd.ExecuteNonQuery();
        }
    }

    private void Exec(string sql)
    {
        using var cmd = _cn.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    public void Dispose()
    {
        lock (_gate)
        {
            try
            {
                Exec("PRAGMA wal_checkpoint(TRUNCATE);");
            }
            catch
            {
                // Best effort — never block shutdown on a checkpoint.
            }
            _cn.Close();
            _cn.Dispose();
        }
        SqliteConnection.ClearAllPools();
    }
}
