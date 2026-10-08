using System.Runtime.InteropServices;
using System.Text;

namespace DiskSizeGrowthMon;

/// <summary>
/// Free space of every fixed volume on the machine, keyed by volume GUID.
///
/// Enumerating volumes (not drive letters) matters here: a folder on C: can be a mount point for a
/// volume that physically lives on E:, and a volume can have no drive letter at all. Freed space
/// then shows up on the volume, not on the letter you would guess.
/// </summary>
public static class VolumeSpace
{
    public sealed record Volume(string Id, string Name, long FreeBytes, long TotalBytes);

    public sealed record Change(string Name, long BeforeBytes, long AfterBytes)
    {
        public long Delta => AfterBytes - BeforeBytes;
    }

    private const uint DriveFixed = 3;

    /// <summary>Snapshot of all fixed volumes that are mounted somewhere (letter or folder).</summary>
    public static List<Volume> Snapshot()
    {
        var result = new List<Volume>();
        var name = new StringBuilder(260);
        IntPtr h = FindFirstVolumeW(name, name.Capacity);
        if (h == new IntPtr(-1)) return result;
        try
        {
            do
            {
                string id = name.ToString();               // \\?\Volume{guid}\
                if (GetDriveTypeW(id) != DriveFixed) continue;

                string? mount = FirstMountPath(id);
                if (mount is null) continue;               // recovery/EFI partitions: not interesting

                if (!GetDiskFreeSpaceExW(id, out _, out ulong total, out ulong free)) continue;
                result.Add(new Volume(id, mount, (long)free, (long)total));
            }
            while (FindNextVolumeW(h, name, name.Capacity));
        }
        finally
        {
            FindVolumeClose(h);
        }

        result.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
        return result;
    }

    /// <summary>Per-volume change between two snapshots (volumes present in both).</summary>
    public static List<Change> Compare(List<Volume> before, List<Volume> after)
    {
        var changes = new List<Change>();
        foreach (var b in before)
        {
            var a = after.Find(v => v.Id == b.Id);
            if (a is not null) changes.Add(new Change(b.Name, b.FreeBytes, a.FreeBytes));
        }
        return changes;
    }

    public static long TotalFree(List<Volume> volumes) => volumes.Sum(v => v.FreeBytes);

    public static string Gb(long bytes) => (bytes / 1073741824.0).ToString("N2");

    public static string SignedGb(long bytes) =>
        (bytes >= 0 ? "+" : "-") + (Math.Abs(bytes) / 1073741824.0).ToString("N2") + " GB";

    private static string? FirstMountPath(string volumeId)
    {
        var buf = new char[512];
        if (!GetVolumePathNamesForVolumeNameW(volumeId, buf, buf.Length, out _)) return null;
        int end = Array.IndexOf(buf, '\0');
        return end > 0 ? new string(buf, 0, end) : null;   // first of a multi-string list
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr FindFirstVolumeW(StringBuilder volumeName, int length);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindNextVolumeW(IntPtr find, StringBuilder volumeName, int length);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FindVolumeClose(IntPtr find);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern uint GetDriveTypeW(string rootPath);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetDiskFreeSpaceExW(string dir, out ulong freeToCaller, out ulong total, out ulong free);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumePathNamesForVolumeNameW(string volumeName, [Out] char[] paths, int length, out int returned);
}
