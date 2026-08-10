using System.Diagnostics;
using System.IO.Enumeration;

namespace DiskSizeGrowthMon;

public sealed record ScanResult(
    List<FolderSize> Folders,
    long TotalBytes,
    long DirectoryCount,
    long FileCount,
    long SkippedCount,
    TimeSpan Elapsed);

/// <summary>
/// Iterative, post-order directory walk that computes recursive folder sizes.
///
/// The whole tree is always walked (otherwise recursive sizes would be wrong), but only
/// folders at depth &lt;= <see cref="AppConfig.MaxDepth"/> whose size reaches
/// <see cref="AppConfig.MinFolderSizeBytes"/> are returned for persistence.
///
/// Recursion is explicit rather than by method call: real trees get deep enough to blow the
/// stack, and an explicit stack also keeps exactly one directory handle open per level.
/// </summary>
public sealed class DiskScanner
{
    private readonly AppConfig _cfg;
    private readonly PauseController _pause;
    private readonly Action<string> _log;

    // Live counters, read by the UI timer on another thread.
    private long _dirCount;
    private long _fileCount;
    private long _bytesSeen;
    private long _skipped;

    public long DirectoryCount => Interlocked.Read(ref _dirCount);
    public long FileCount => Interlocked.Read(ref _fileCount);
    public long BytesSeen => Interlocked.Read(ref _bytesSeen);
    public long SkippedCount => Interlocked.Read(ref _skipped);

    public DiskScanner(AppConfig cfg, PauseController pause, Action<string> log)
    {
        _cfg = cfg;
        _pause = pause;
        _log = log;
    }

    private static readonly EnumerationOptions Options = new()
    {
        RecurseSubdirectories = false,
        // We do our own recursion; swallowing ACL failures keeps a single locked folder
        // from aborting a whole drive.
        IgnoreInaccessible = true,
        AttributesToSkip = 0, // hidden + system folders count too
        ReturnSpecialDirectories = false,
        MatchType = MatchType.Simple
    };

    private readonly record struct Entry(bool IsDirectory, long Length, string? FullPath);

    private static readonly FileSystemEnumerable<Entry>.FindTransform Transform = static (ref FileSystemEntry e) =>
    {
        bool isDir = e.IsDirectory;
        if (!isDir)
            return new Entry(false, e.Length, null);

        // Junctions / symlinks point at content owned by some other folder. Following them
        // would double-count at best and loop forever at worst.
        bool isReparse = (e.Attributes & FileAttributes.ReparsePoint) != 0;
        return new Entry(true, 0L, isReparse ? null : e.ToFullPath());
    };

    private sealed class Frame
    {
        public required string Path;
        public required int Depth;
        public long Total;
        public required IEnumerator<Entry> Iterator;
    }

    public ScanResult Scan(string driveRoot, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        var results = new List<FolderSize>();
        long minBytes = _cfg.MinFolderSizeBytes;
        int maxDepth = _cfg.MaxDepth;
        long deepLogStamp = 0;

        var stack = new Stack<Frame>();
        stack.Push(NewFrame(driveRoot, 0));
        _log(driveRoot);

        long rootTotal = 0;

        while (stack.Count > 0)
        {
            ct.ThrowIfCancellationRequested();
            _pause.Wait(ct);

            Frame frame = stack.Peek();

            bool moved;
            try
            {
                moved = frame.Iterator.MoveNext();
            }
            catch (Exception ex)
            {
                // IgnoreInaccessible handles ACLs; this catches the rest (bad reparse
                // targets, device errors, paths the OS refuses even for admins).
                Interlocked.Increment(ref _skipped);
                _log($"  [skipped] {frame.Path}  ({ex.GetType().Name}: {ex.Message})");
                moved = false;
            }

            if (!moved)
            {
                stack.Pop();
                frame.Iterator.Dispose();
                Interlocked.Increment(ref _dirCount);

                if (frame.Depth <= maxDepth && frame.Total >= minBytes)
                    results.Add(new FolderSize(frame.Path, frame.Depth, frame.Total));

                if (stack.Count > 0)
                    stack.Peek().Total += frame.Total;
                else
                    rootTotal = frame.Total;

                continue;
            }

            Entry entry = frame.Iterator.Current;

            if (!entry.IsDirectory)
            {
                frame.Total += entry.Length;
                Interlocked.Increment(ref _fileCount);
                Interlocked.Add(ref _bytesSeen, entry.Length);
                continue;
            }

            if (entry.FullPath is null) continue;              // reparse point
            if (IsExcluded(entry.FullPath)) { _log($"  [excluded] {entry.FullPath}"); continue; }

            int childDepth = frame.Depth + 1;

            // Every folder we might report on gets a log line. Below that the tree fans out
            // into tens of thousands of folders per second, so it is sampled instead.
            if (childDepth <= maxDepth)
            {
                _log(entry.FullPath);
            }
            else
            {
                long now = sw.ElapsedMilliseconds;
                if (now - deepLogStamp >= 150)
                {
                    deepLogStamp = now;
                    _log(entry.FullPath);
                }
            }

            stack.Push(NewFrame(entry.FullPath, childDepth));
        }

        sw.Stop();
        return new ScanResult(results, rootTotal, DirectoryCount, FileCount, SkippedCount, sw.Elapsed);
    }

    private static Frame NewFrame(string path, int depth) => new()
    {
        Path = path,
        Depth = depth,
        Iterator = new FileSystemEnumerable<Entry>(path, Transform, Options).GetEnumerator()
    };

    private bool IsExcluded(string fullPath)
    {
        foreach (string ex in _cfg.ExcludedPaths)
        {
            if (fullPath.Equals(ex, StringComparison.OrdinalIgnoreCase)) return true;
            if (fullPath.StartsWith(ex + "\\", StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }
}
