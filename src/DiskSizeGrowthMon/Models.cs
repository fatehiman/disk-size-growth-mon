using System.Globalization;

namespace DiskSizeGrowthMon;

/// <summary>A folder as persisted by one scan. <paramref name="SizeBytes"/> is recursive (folder + all descendants).</summary>
public readonly record struct FolderSize(string Path, int Depth, long SizeBytes);

/// <summary>One row of a stored growth report.</summary>
public readonly record struct ReportRow(int Rank, string Path, long PrevBytes, long CurrBytes, long GrowthBytes);

/// <summary>A completed scan, as listed in the history box.</summary>
public sealed record ScanSummary(
    long Id,
    string Drive,
    DateTime StartedLocal,
    long? PrevScanId,
    DateTime? PrevStartedLocal,
    int FolderCount,
    long TotalBytes,
    int MaxDepth,
    long MinSizeBytes,
    int DurationMs,
    long? FreeBytes = null,
    long? DriveSizeBytes = null)
{
    private const double GB = 1024d * 1024d * 1024d;

    /// <summary>
    /// Free space is null for scans recorded before it was captured; those keep the old label.
    /// </summary>
    public string Label => FreeBytes is long free
        ? $"{StartedLocal:yyyy-MM-dd HH:mm} {Drive} ({(free / GB).ToString("F1", CultureInfo.InvariantCulture)}GB)"
        : $"{StartedLocal:yyyy-MM-dd HH:mm} {Drive}";

    public override string ToString() => Label;
}
