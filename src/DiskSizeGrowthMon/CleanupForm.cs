using System.Diagnostics;
using System.Text;

namespace DiskSizeGrowthMon;

/// <summary>
/// Runs the cleanup batch files that ship next to the executable.
///
/// Tick any number of scripts and press Run: they execute one after another, never in parallel -
/// two scripts clearing overlapping caches at once produce interleaved output nobody can read and
/// race each other over the same directories. Run turns into Stop while the queue is going.
/// Free space on every fixed volume is measured before and after, so the reclaimed total is
/// real even when a folder on C: is a mount point for a volume that lives on E:.
/// </summary>
public sealed class CleanupForm : Form
{
    /// <summary>Subfolder beside the exe that holds the shipped scripts. Its .bat files are listed too.</summary>
    public const string ScriptSubfolder = "cleanup";

    private CheckedListBox _lstScripts = null!;
    private CheckBox _chkAll = null!;
    private bool _syncingAll;
    private TextBox _txtOutput = null!;
    private Button _btnRun = null!;
    private Button _btnRefresh = null!;
    private Button _btnClose = null!;
    private Label _lblStatus = null!;

    private Process? _proc;
    private Stopwatch? _elapsed;
    private bool _running;           // a queue is in progress
    private bool _stopRequested;
    private int _queueIndex, _queueCount;
    private string _queueName = "";
    private string _lastSummary = "";

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
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 196f));   // script list
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 38f));    // button strip
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));    // output
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 24f));    // status

        _lstScripts = new CheckedListBox
        {
            Dock = DockStyle.Fill,
            Font = monospace,
            IntegralHeight = false,
            CheckOnClick = true
        };
        // ItemCheck fires before the new state is stored, so look at it once the event has finished.
        _lstScripts.ItemCheck += (_, _) => BeginInvoke(SyncSelectAll);

        _chkAll = new CheckBox { Text = "Select all", Dock = DockStyle.Top, Height = 24, Padding = new Padding(4, 0, 0, 0) };
        _chkAll.CheckedChanged += (_, _) =>
        {
            if (_syncingAll) return;
            for (int i = 0; i < _lstScripts.Items.Count; i++) _lstScripts.SetItemChecked(i, _chkAll.Checked);
        };

        var strip = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            WrapContents = false,
            Padding = new Padding(0, 4, 0, 0)
        };

        _btnRun = new Button { Text = "Run", Size = new Size(80, 26) };
        _btnRun.Click += (_, _) => { if (_running) StopQueue(); else _ = RunCheckedAsync(); };

        _btnRefresh = new Button { Text = "Refresh list", Size = new Size(100, 26), Margin = new Padding(8, 3, 3, 3) };
        _btnRefresh.Click += (_, _) => LoadScripts();

        var btnFolder = new Button { Text = "Open folder", Size = new Size(100, 26), Margin = new Padding(8, 3, 3, 3) };
        btnFolder.Click += (_, _) => PathActions.OpenFolder(this, ScriptFolder);

        var btnClear = new Button { Text = "Clear output", Size = new Size(100, 26), Margin = new Padding(8, 3, 3, 3) };
        btnClear.Click += (_, _) => _txtOutput.Clear();

        _btnClose = new Button { Text = "Close", Size = new Size(80, 26), Margin = new Padding(8, 3, 3, 3) };
        _btnClose.Click += (_, _) => Close();

        strip.Controls.AddRange(new Control[] { _btnRun, _btnRefresh, btnFolder, btnClear, _btnClose });

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
            Text = "Tick the scripts to run, then press Run."
        };

        var lblHint = new Label
        {
            Dock = DockStyle.Top,
            Height = 20,
            Text = $"Batch files in {ScriptFolder} and beside the executable. Ticked ones run one by one, elevated.",
            ForeColor = SystemColors.GrayText
        };

        var listPanel = new Panel { Dock = DockStyle.Fill };
        listPanel.Controls.Add(_lstScripts);
        listPanel.Controls.Add(_chkAll);
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
        if (_running) return;

        var previouslyChecked = _lstScripts.CheckedItems.OfType<ScriptItem>()
            .Select(i => i.FullPath).ToHashSet(StringComparer.OrdinalIgnoreCase);

        var found = new List<ScriptItem>();
        // The cleanup\ subfolder first (that is where the shipped scripts live), then any loose
        // .bat the user dropped beside the exe.
        Collect(ScriptFolder, ScriptSubfolder + "\\");
        Collect(ExeFolder, "");

        _lstScripts.BeginUpdate();
        _lstScripts.Items.Clear();
        foreach (var item in found) _lstScripts.Items.Add(item, previouslyChecked.Contains(item.FullPath));
        _lstScripts.EndUpdate();
        SyncSelectAll();

        _lblStatus.Text = _lstScripts.Items.Count == 0
            ? $"No .bat files found in {ScriptFolder} or {ExeFolder}."
            : $"{_lstScripts.Items.Count} script(s). Tick the ones to run, then press Run.";

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

    private void SyncSelectAll()
    {
        if (IsDisposed) return;
        _syncingAll = true;
        _chkAll.Checked = _lstScripts.Items.Count > 0 && _lstScripts.CheckedItems.Count == _lstScripts.Items.Count;
        _syncingAll = false;
    }

    private async Task RunCheckedAsync()
    {
        var queue = _lstScripts.CheckedItems.OfType<ScriptItem>().ToList();
        if (queue.Count == 0)
        {
            MessageBox.Show(this, "Tick at least one script first.", AppConfig.AppTitle,
                            MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        _running = true;
        _stopRequested = false;
        _queueCount = queue.Count;
        _queueIndex = 0;
        _queueName = "";
        _elapsed = Stopwatch.StartNew();
        SetRunningUi(true);

        var before = VolumeSpace.Snapshot();
        Append($"##### queue of {queue.Count} script(s) started {DateTime.Now:HH:mm:ss} #####");

        int ran = 0, failed = 0;
        var perScript = new List<(string Name, long Gain, int Exit)>();

        foreach (var script in queue)
        {
            if (_stopRequested || IsDisposed) break;

            _queueIndex = ran + 1;
            _queueName = script.Display;

            if (!File.Exists(script.FullPath))
            {
                Append($"=== {script.Display} no longer exists - skipped ===");
                failed++;
                continue;
            }

            long freeBefore = VolumeSpace.TotalFree(VolumeSpace.Snapshot());
            int exit = await RunScriptAsync(script, ran + 1, queue.Count);
            if (IsDisposed) return;
            long gain = VolumeSpace.TotalFree(VolumeSpace.Snapshot()) - freeBefore;

            ran++;
            if (exit != 0 && !_stopRequested) failed++;
            perScript.Add((script.Display, gain, exit));
        }

        if (IsDisposed) return;
        var after = VolumeSpace.Snapshot();

        PrintSummary(queue.Count, ran, failed, perScript, VolumeSpace.Compare(before, after));

        _running = false;
        _elapsed?.Stop();
        SetRunningUi(false);
    }

    private void PrintSummary(int total, int ran, int failed,
                              List<(string Name, long Gain, int Exit)> perScript,
                              List<VolumeSpace.Change> changes)
    {
        long totalDelta = changes.Sum(c => c.Delta);
        var sb = new StringBuilder();
        sb.AppendLine();
        sb.AppendLine("################ SUMMARY ################");
        sb.AppendLine(_stopRequested
            ? $"Stopped by user: {ran} of {total} script(s) started, {failed} reported a problem."
            : $"{ran} of {total} script(s) ran, {failed} reported a problem.");

        sb.AppendLine();
        sb.AppendLine("Free space change per script (all volumes together):");
        foreach (var (name, gain, exit) in perScript)
            sb.AppendLine($"  {VolumeSpace.SignedGb(gain),14}  {name}{(exit != 0 ? $"   (exit {exit})" : "")}");

        sb.AppendLine();
        sb.AppendLine("Free space per volume, before -> after:");
        foreach (var c in changes)
            sb.AppendLine($"  {c.Name,-10} {VolumeSpace.Gb(c.BeforeBytes),10} GB -> {VolumeSpace.Gb(c.AfterBytes),10} GB   {VolumeSpace.SignedGb(c.Delta)}");

        sb.AppendLine();
        sb.AppendLine($"TOTAL RECLAIMED: {VolumeSpace.SignedGb(totalDelta)}");
        sb.AppendLine("Net change in free space over every fixed volume. Other programs write while the");
        sb.AppendLine("scripts run, and a move between volumes (e.g. C: to E:) nets to about zero.");
        sb.AppendLine("#########################################");
        Append(sb.ToString());

        _lastSummary = $"Last run: {VolumeSpace.SignedGb(totalDelta)} in total " +
                       $"(free {VolumeSpace.Gb(changes.Sum(c => c.BeforeBytes))} -> {VolumeSpace.Gb(changes.Sum(c => c.AfterBytes))} GB, all volumes).";
    }

    /// <summary>Runs one script to the end and returns its exit code (-1 if it was killed or failed to start).</summary>
    private Task<int> RunScriptAsync(ScriptItem script, int index, int count)
    {
        var tcs = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);

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
        var sw = Stopwatch.StartNew();
        try
        {
            proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
            proc.OutputDataReceived += (_, e) => { if (e.Data is not null) AppendThreadSafe(e.Data); };
            proc.ErrorDataReceived += (_, e) => { if (e.Data is not null) AppendThreadSafe(e.Data); };
            proc.Exited += (_, _) => OnProcessExited(proc, script, sw, tcs);

            if (!proc.Start()) throw new InvalidOperationException("cmd.exe did not start.");
        }
        catch (Exception ex)
        {
            Append($"=== Could not start {script.Display}: {ex.Message} ===");
            tcs.TrySetResult(-1);
            return tcs.Task;
        }

        _proc = proc;
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();
        try { proc.StandardInput.Close(); } catch { /* already gone */ }

        Append($"=== [{index}/{count}] {script.Display}  started {DateTime.Now:HH:mm:ss} ===");
        return tcs.Task;
    }

    private void OnProcessExited(Process proc, ScriptItem script, Stopwatch sw, TaskCompletionSource<int> tcs)
    {
        // Exited fires on a thread-pool thread; WaitForExit() with no timeout here flushes the two
        // async output readers, so nothing is lost between the last line and the summary below.
        try { proc.WaitForExit(); } catch { /* ignore */ }

        int exitCode;
        try { exitCode = proc.ExitCode; } catch { exitCode = -1; }

        void Finish()
        {
            string how = _stopRequested ? "stopped by user" : $"exit code {exitCode}";
            Append($"=== {script.Display} finished in {sw.Elapsed:hh\\:mm\\:ss} - {how} ===");
            Append("");

            _proc = null;
            try { proc.Dispose(); } catch { /* ignore */ }
            tcs.TrySetResult(_stopRequested ? -1 : exitCode);
        }

        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(Finish); } catch (ObjectDisposedException) { /* form closed under us */ }
    }

    private void StopQueue()
    {
        _stopRequested = true;
        _btnRun.Enabled = false;
        _btnRun.Text = "Stopping...";
        Append("=== stop requested - terminating the current script and skipping the rest ===");
        KillRunning();
    }

    private void KillRunning()
    {
        Process? proc = _proc;
        if (proc is null || proc.HasExited) return;

        // Kill(true) walks the child tree, which matters: the visible process is cmd.exe and the
        // work is being done by dism / docker / diskpart underneath it.
        try
        {
            proc.Kill(entireProcessTree: true);
        }
        catch (Exception ex)
        {
            Append($"[kill failed: {ex.Message}]");
        }
    }

    private void SetRunningUi(bool running)
    {
        _lstScripts.Enabled = !running;   // one queue at a time
        _chkAll.Enabled = !running;
        _btnRefresh.Enabled = !running;
        _btnRun.Enabled = true;
        _btnRun.Text = running ? "Stop" : "Run";
        if (!running) UpdateStatus();
    }

    private void UpdateStatus()
    {
        if (!_running)
        {
            if (_elapsed is not null)
                _lblStatus.Text = _lastSummary.Length > 0 ? _lastSummary : "Idle. Tick scripts and press Run.";
            return;
        }

        _lblStatus.Text = $"Running {_queueIndex} of {_queueCount}: {_queueName}   elapsed {_elapsed?.Elapsed:hh\\:mm\\:ss}   (Stop ends it and skips the rest)";
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
        if (_running)
        {
            var answer = MessageBox.Show(
                this,
                "Cleanup scripts are still running.\r\n\r\nStop them and close this window?",
                AppConfig.AppTitle, MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);

            if (answer != DialogResult.Yes)
            {
                e.Cancel = true;
                return;
            }

            _stopRequested = true;
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
