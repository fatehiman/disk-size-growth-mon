using System.Diagnostics;

namespace DiskSizeGrowthMon;

/// <summary>
/// Opening report paths in Explorer. Reported folders can be gone by the time you click them — the
/// report is a snapshot of a scan that may be days old, and cleaning up is the whole point of the
/// tool — so "not there any more" is an expected outcome, not an error.
/// </summary>
public static class PathActions
{
    /// <summary>Opens the folder itself in a new Explorer window.</summary>
    public static void OpenFolder(IWin32Window owner, string path)
    {
        if (!Exists(owner, path, out string full)) return;
        Launch(owner, "explorer.exe", $"\"{full}\"");
    }

    /// <summary>Opens the parent folder with the target selected — the usual "reveal in Explorer".</summary>
    public static void RevealInExplorer(IWin32Window owner, string path)
    {
        if (!Exists(owner, path, out string full)) return;

        // A drive root has no parent to select it in; just open it.
        string? parent = Path.GetDirectoryName(full);
        if (string.IsNullOrEmpty(parent))
        {
            Launch(owner, "explorer.exe", $"\"{full}\"");
            return;
        }

        Launch(owner, "explorer.exe", $"/select,\"{full}\"");
    }

    public static void OpenTerminalAt(IWin32Window owner, string path)
    {
        if (!Exists(owner, path, out string full)) return;

        var psi = new ProcessStartInfo
        {
            FileName = Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe",
            Arguments = "/k",
            WorkingDirectory = full,
            UseShellExecute = true
        };
        Launch(owner, psi);
    }

    public static void CopyToClipboard(IWin32Window owner, string text)
    {
        try
        {
            if (string.IsNullOrEmpty(text)) Clipboard.Clear();
            else Clipboard.SetText(text);
        }
        catch (Exception ex)
        {
            // The clipboard is a shared, lockable resource; another process can hold it.
            MessageBox.Show(owner, $"Could not copy to the clipboard: {ex.Message}",
                            AppConfig.AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private static bool Exists(IWin32Window owner, string path, out string full)
    {
        full = "";
        if (string.IsNullOrWhiteSpace(path)) return false;

        try
        {
            full = Path.GetFullPath(path);
        }
        catch (Exception ex)
        {
            MessageBox.Show(owner, $"{path}\r\n\r\nis not a usable path: {ex.Message}",
                            AppConfig.AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }

        if (Directory.Exists(full) || File.Exists(full)) return true;

        MessageBox.Show(owner,
                        $"{full}\r\n\r\ndoes not exist. A folder from a report was there when that scan ran.",
                        AppConfig.AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Information);
        return false;
    }

    private static void Launch(IWin32Window owner, string fileName, string arguments) =>
        Launch(owner, new ProcessStartInfo { FileName = fileName, Arguments = arguments, UseShellExecute = true });

    private static void Launch(IWin32Window owner, ProcessStartInfo psi)
    {
        try
        {
            using Process? p = Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(owner, $"Could not run {psi.FileName}: {ex.Message}",
                            AppConfig.AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }
}
