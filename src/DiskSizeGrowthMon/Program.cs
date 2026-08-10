using System.Security.Principal;

namespace DiskSizeGrowthMon;

internal static class Program
{
    /// <summary>Global so a second instance is blocked across user sessions, not just this one.</summary>
    private const string MutexName = @"Global\DiskSizeGrowthMon.{7F4C1C6A-2B33-4E1B-9E4C-6E5F2A9C1D01}";

    private const string AppTitle = AppConfig.AppTitle;

    [STAThread]
    private static void Main()
    {
        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        using var mutex = new Mutex(initiallyOwned: true, MutexName, out bool isFirstInstance);
        if (!isFirstInstance)
        {
            MessageBox.Show(
                $"{AppTitle} is already running.\r\n\r\nOnly one instance may run at a time, because a second scan " +
                "would compete for the same database and thrash the disk.",
                AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        try
        {
            AppConfig cfg = AppConfig.LoadOrCreate();

            if (!IsElevated())
            {
                MessageBox.Show(
                    "This process is not elevated, so protected system folders will be reported as empty.\r\n\r\n" +
                    "Close it and start it again via \"Run as administrator\".",
                    AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }

            if (cfg.LoadWarnings.Count > 0)
            {
                MessageBox.Show(
                    $"Problems in {cfg.ConfigFilePath}:\r\n\r\n - " + string.Join("\r\n - ", cfg.LoadWarnings),
                    AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }

            using var db = new Database(cfg.ResolvedDatabasePath);
            using var form = new MainForm(cfg, db);
            Application.Run(form);
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Fatal error:\r\n\r\n{ex}", AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            mutex.ReleaseMutex();
        }
    }

    private static bool IsElevated()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }
}
