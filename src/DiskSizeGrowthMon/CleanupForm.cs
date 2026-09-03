using System.Diagnostics;
using System.Text;

namespace DiskSizeGrowthMon;

/// <summary>
/// Runs the cleanup batch files that ship next to the executable.
///
/// One script at a time, by design: two scripts clearing overlapping caches in parallel produce
/// interleaved output nobody can read and race each other over the same directories. The list is
/// disabled while a script runs and re-enabled when it exits.
/// </summary>
public sealed class CleanupForm : Form
{
    /// <summary>Subfolder beside the exe that holds the shipped scripts. Its .bat files are listed too.</summary>
    public const string ScriptSubfolder = "cleanup";

    private ListBox _lstScripts = null!;
    private TextBox _txtOutput = null!;
    private Button _btnKill = null!;
    private Button _btnRefresh = null!;
    private Button _btnClose = null!;
    private Label _lblStatus = null!;

    private Process? _proc;
    private Stopwatch? _elapsed;
    private bool _killRequested;

    // cmd.exe spawns children (dism, docker, diskpart...), so the whole tree is written to a job-like
    // taskkill /T. Output arrives on two background threads; every touch of the UI goes through Invoke.
    private readonly System.Windows.Forms.Timer _uiTimer = new() { Interval = 250 };

    public CleanupForm()
    {
        BuildUi();
        LoadScripts();

        _uiTimer.Tick += (_, _) => UpdateStatus();
        _uiTimer.Start();
    }

    private void BuildUi()
    {
        Text = "Cleanup scripts — " + AppConfig.AppTitle;
        StartPosition = FormStartPosition.CenterParent;
        ClientSize = new Size(900, 620);
        MinimumSize = new Size(700, 480);
        ShowIcon = false;
        MinimizeBox = false;
        Font = SystemFonts.MessageBoxFont ?? new Font("Segoe UI", 9f);

        var monospace = new Font("Consolas", 9f);

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 4,
            Padding = new Padding(10)
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 170f));   // script list
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 38f));    // button strip
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));    // output
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 24f));    // status

        _lstScripts = new ListBox
        {
            Dock = DockStyle.Fill,
            Font = monospace,
            IntegralHeight = false,
            SelectionMode = SelectionMode.One
        };
        _lstScripts.DoubleClick += (_, _) => RunSelected();
        _lstScripts.KeyDown += (_, e) =>
        {
            if (e.KeyCode is Keys.Enter) { e.Handled = true; RunSelected(); }
        };

        var strip = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Padding = new Padding(0, 4, 0, 0)
        };

        _btnKill = new Button { Text = "Kill", Size = new Size(70, 26), Enabled = false };
        _btnKill.Click += (_, _) => KillRunning();

        _btnRefresh = new Button { Text = "Refresh list", Size = new Size(100, 26), Margin = new Padding(8, 3, 3, 3) };
        _btnRefresh.Click += (_, _) => LoadScripts();

        var btnFolder = new Button { Text = "Open folder", Size = new Size(100, 26), Margin = new Padding(8, 3, 3, 3) };
        btnFolder.Click += (_, _) => PathActions.OpenFolder(this, ScriptFolder);

        var btnClear = new Button { Text = "Clear output", Size = new Size(100, 26), Margin = new Padding(8, 3, 3, 3) };
        btnClear.Click += (_, _) => _txtOutput.Clear();

        _btnClose = new Button { Text = "Close", Size = new Size(80, 26), Margin = new Padding(8, 3, 3, 3) };
        _btnClose.Click += (_, _) => Close();

        strip.Controls.AddRange(new Control[] { _btnKill, _btnRefresh, btnFolder, btnClear, _btnClose });

        _txtOutput = new TextBox
        {
            Dock = DockStyle.Fill,
            Multiline = true,
            ReadOnly = true,
            WordWrap = false,
            ScrollBars = ScrollBars.Both,
            Font = monospace,
            BackColor = Color.FromArgb(30, 30, 30),
            ForeColor = Color.FromArgb(210, 210, 210),
            BorderStyle = BorderStyle.FixedSingle
        };

        _lblStatus = new Label
        {
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleLeft,
            Text = "Double-click a script to run it."
        };

        var lblHint = new Label
        {
            Dock = DockStyle.Top,
            Height = 20,
            Text = $"Batch files in {ScriptFolder} and beside the executable. Double-click to run — they run elevated.",
            ForeColor = SystemColors.GrayText
        };

        var listPanel = new Panel { Dock = DockStyle.Fill };
        listPanel.Controls.Add(_lstScripts);
        listPanel.Controls.Add(lblHint);

        root.Controls.Add(listPanel, 0, 0);
        root.Controls.Add(strip, 0, 1);
        root.Controls.Add(_txtOutput, 0, 2);
        root.Controls.Add(_lblStatus, 0, 3);
        Controls.Add(root);

        CancelButton = _btnClose;
    }

    private static string ExeFolder => AppContext.BaseDirectory.TrimEnd('\\');

    private static string ScriptFolder => Path.Combine(ExeFolder, ScriptSubfolder);

    // ------------------------------------------------------------------ script list

    private sealed record ScriptItem(string FullPath, string Display)
    {
        public override string ToString() => Display;
    }

    private void LoadScripts()
    {
        if (IsRunning) return;

        string? previous = (_lstScripts.SelectedItem as ScriptItem)?.FullPath;

        var found = new List<ScriptItem>();
        // The cleanup\ subfolder first (that is where the shipped scripts live), then any loose
        // .bat the user dropped beside the exe.
        Collect(ScriptFolder, ScriptSubfolder + "\\");
        Collect(ExeFolder, "");

        _lstScripts.BeginUpdate();
        _lstScripts.Items.Clear();
        foreach (var s in found) _lstScripts.Items.Add(s);
        _lstScripts.EndUpdate();

        if (_lstScripts.Items.Count == 0)
        {
            _lblStatus.Text = $"No .bat files found in {ScriptFolder} or {ExeFolder}.";
            return;
        }

        int index = previous is null ? 0 : found.FindIndex(s =>
            string.Equals(s.FullPath, previous, StringComparison.OrdinalIgnoreCase));
        _lstScripts.SelectedIndex = index < 0 ? 0 : index;
        _lblStatus.Text = $"{_lstScripts.Items.Count} script(s). Double-click one to run it.";

        void Collect(string folder, string prefix)
        {
            try
            {
                if (!Directory.Exists(folder)) return;
                foreach (string file in Directory.EnumerateFiles(folder, "*.bat", SearchOption.TopDirectoryOnly)
                                                 .OrderBy(f => f, StringComparer.OrdinalIgnoreCase))
                {
                    found.Add(new ScriptItem(file, prefix + Path.GetFileName(file)));
                }
            }
            catch (Exception ex)
            {
                Append($"[cannot list {folder}: {ex.Message}]");
            }
        }
    }

    // ------------------------------------------------------------------ running

    private bool IsRunning => _proc is { HasExited: false };

    private void RunSelected()
    {
        if (IsRunning) return;
        if (_lstScripts.SelectedItem is not ScriptItem script) return;
        if (!File.Exists(script.FullPath))
        {
            MessageBox.Show(this, $"{script.FullPath} no longer exists.", AppConfig.AppTitle,
                            MessageBoxButtons.OK, MessageBoxIcon.Warning);
            LoadScripts();
            return;
        }

        var psi = new ProcessStartInfo
        {
            FileName = Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe",
            // /d skips AutoRun registry commands, which otherwise inject noise into the output.
            Arguments = $"/d /c \"\"{script.FullPath}\"\"",
            WorkingDirectory = Path.GetDirectoryName(script.FullPath)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,     // so a script that reads input gets EOF instead of hanging forever
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        // The shipped scripts start with `chcp 65001 > nul`, which is what makes the UTF-8 decoding
        // above correct. A user's own .bat that does not will still be readable for plain ASCII output.

        Process proc;
        try
        {
            proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
            proc.OutputDataReceived += (_, e) => { if (e.Data is not null) AppendThreadSafe(e.Data); };
            proc.ErrorDataReceived += (_, e) => { if (e.Data is not null) AppendThreadSafe(e.Data); };
            proc.Exited += (_, _) => OnProcessExited(proc);

            if (!proc.Start()) throw new InvalidOperationException("cmd.exe did not start.");
        }
        catch (Exception ex)
        {
            Append($"=== Could not start {script.Display}: {ex.Message} ===");
            return;
        }

        _proc = proc;
        _killRequested = false;
        _elapsed = Stopwatch.StartNew();

        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
        try { proc.StandardInput.Close(); } catch { /* already gone */ }

        Append($"=== {script.Display}  started {DateTime.Now:HH:mm:ss} ===");
        SetRunningUi(true);
    }

    private void OnProcessExited(Process proc)
    {
        // Exited fires on a thread-pool thread; WaitForExit() with no timeout here flushes the two
        // async output readers, so nothing is lost between the last line and the summary below.
        try { proc.WaitForExit(); } catch { /* ignore */ }

        int exitCode;
        try { exitCode = proc.ExitCode; } catch { exitCode = -1; }

        void Finish()
        {
            _elapsed?.Stop();
            string how = _killRequested ? "killed by user" : $"exit code {exitCode}";
            Append($"=== finished in {_elapsed?.Elapsed:hh\\:mm\\:ss} — {how} ===");
            Append("");

            _proc = null;
            SetRunningUi(false);
            try { proc.Dispose(); } catch { /* ignore */ }
        }

        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(Finish); } catch (ObjectDisposedException) { /* form closed under us */ }
    }

    private void KillRunning()
    {
        Process? proc = _proc;
        if (proc is null || proc.HasExited) return;

        _killRequested = true;
        _btnKill.Enabled = false;
        Append("=== kill requested — terminating the script and everything it started ===");

        // Kill(true) walks the child tree, which matters: the visible process is cmd.exe and the
        // work is being done by dism / docker / diskpart underneath it.
        try
        {
            proc.Kill(entireProcessTree: true);
        }
        catch (Exception ex)
        {
            Append($"[kill failed: {ex.Message}]");
            _btnKill.Enabled = true;
        }
    }

    private void SetRunningUi(bool running)
    {
        _lstScripts.Enabled = !running;   // one script at a time
        _btnRefresh.Enabled = !running;
        _btnKill.Enabled = running;
        if (!running) UpdateStatus();
    }

    private void UpdateStatus()
    {
        if (!IsRunning)
        {
            if (_elapsed is not null) _lblStatus.Text = "Idle. Double-click a script to run it.";
            return;
        }

        string name = (_lstScripts.SelectedItem as ScriptItem)?.Display ?? "script";
        _lblStatus.Text = $"Running {name}   elapsed {_elapsed?.Elapsed:hh\\:mm\\:ss}   (Kill stops it)";
    }

    // ------------------------------------------------------------------ output

    private void AppendThreadSafe(string line)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(() => Append(line)); } catch (ObjectDisposedException) { /* closing */ }
    }

    private void Append(string line)
    {
        if (IsDisposed) return;
        _txtOutput.AppendText(line + "\r\n");
    }

    // ------------------------------------------------------------------ shutdown

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (IsRunning)
        {
            var answer = MessageBox.Show(
                this,
                "A cleanup script is still running.\r\n\r\nKill it and close this window?",
                AppConfig.AppTitle, MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);

            if (answer != DialogResult.Yes)
            {
                e.Cancel = true;
                return;
            }

            KillRunning();
        }

        base.OnFormClosing(e);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _uiTimer.Stop();
        _uiTimer.Dispose();

        Process? proc = _proc;
        _proc = null;
        if (proc is not null)
        {
            try { if (!proc.HasExited) proc.Kill(entireProcessTree: true); } catch { /* ignore */ }
            try { proc.Dispose(); } catch { /* ignore */ }
        }

        base.OnFormClosed(e);
    }
}
