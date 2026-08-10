using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace DiskSizeGrowthMon;

public sealed class MainForm : Form
{
    private const double GB = 1024d * 1024d * 1024d;

    private readonly AppConfig _cfg;
    private readonly Database _db;

    // --- scan part ---
    private ListBox _lstDrives = null!;
    private Button _btnScan = null!;
    private Button _btnStop = null!;
    private TextBox _txtLog = null!;
    private Label _lblStatus = null!;

    // --- report part ---
    private ListBox _lstScans = null!;
    private DataGridView _grid = null!;
    private Label _lblReportHeader = null!;
    private SplitContainer _split = null!;

    private readonly System.Windows.Forms.Timer _uiTimer = new() { Interval = 100 };

    // Scan state. All mutated on the UI thread except the log queue.
    private Task? _scanTask;
    private CancellationTokenSource? _cts;
    private PauseController? _pause;
    private DiskScanner? _scanner;
    private Stopwatch? _elapsed;
    private string _scanDrive = "";
    private bool _forceClose;
    private bool _shuttingDown;

    private readonly ConcurrentQueue<string> _logQueue = new();
    private int _logQueueDepth;
    private int _logLineCount;

    private const int LogQueueCap = 4000;   // producer drops beyond this; the log is a hint, not an audit trail
    private const int LogDrainPerTick = 80; // ~800 lines/sec on screen

    public MainForm(AppConfig cfg, Database db)
    {
        _cfg = cfg;
        _db = db;

        BuildUi();
        LoadDrives();
        ReloadScanHistory(selectId: null);

        _uiTimer.Tick += OnUiTick;
        _uiTimer.Start();
    }

    // ------------------------------------------------------------------ UI

    private void BuildUi()
    {
        Text = AppConfig.AppTitle;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(1040, 780);
        MinimumSize = new Size(900, 640);
        AutoScaleMode = AutoScaleMode.Font;
        Font = SystemFonts.MessageBoxFont ?? new Font("Segoe UI", 9f);

        var monospace = new Font("Consolas", 9f);

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 2,
            Padding = new Padding(8)
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));

        // ---------------- scan group ----------------
        var gbScan = new GroupBox { Text = "Scan", Dock = DockStyle.Fill, Padding = new Padding(8) };

        int logHeight = monospace.Height * 7 + 8;   // exactly 7 visible lines

        var scanLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3 };
        scanLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
        scanLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 92f));
        scanLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, logHeight));
        scanLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 24f));

        var topRow = new Panel { Dock = DockStyle.Fill };

        _lstDrives = new ListBox
        {
            Dock = DockStyle.Left,
            Width = 400,
            Font = monospace,
            IntegralHeight = false,
            SelectionMode = SelectionMode.One
        };
        _lstDrives.SelectedIndexChanged += (_, _) => UpdateButtons();

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Left,
            FlowDirection = FlowDirection.LeftToRight,
            Padding = new Padding(10, 26, 0, 0),
            AutoSize = true,
            WrapContents = false
        };

        _btnScan = new Button { Text = "Scan", Size = new Size(110, 34) };
        _btnScan.Click += OnScanOrPauseClick;

        _btnStop = new Button { Text = "Stop", Size = new Size(110, 34), Enabled = false, Margin = new Padding(8, 3, 3, 3) };
        _btnStop.Click += OnStopClick;

        buttons.Controls.Add(_btnScan);
        buttons.Controls.Add(_btnStop);

        topRow.Controls.Add(buttons);
        topRow.Controls.Add(_lstDrives);

        _txtLog = new TextBox
        {
            Dock = DockStyle.Fill,
            Multiline = true,
            ReadOnly = true,
            WordWrap = false,
            ScrollBars = ScrollBars.Both,
            Font = monospace,
            BackColor = Color.FromArgb(30, 30, 30),
            ForeColor = Color.FromArgb(210, 210, 210),
            BorderStyle = BorderStyle.FixedSingle,
            TabStop = false
        };

        _lblStatus = new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Text = "Idle." };

        scanLayout.Controls.Add(topRow, 0, 0);
        scanLayout.Controls.Add(_txtLog, 0, 1);
        scanLayout.Controls.Add(_lblStatus, 0, 2);
        gbScan.Controls.Add(scanLayout);

        // Group box chrome + the three fixed rows.
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 92 + logHeight + 24 + 44));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));

        // ---------------- report group ----------------
        var gbReport = new GroupBox { Text = "Growth report", Dock = DockStyle.Fill, Padding = new Padding(8) };

        // SplitterDistance can only be set once the container is at its real width, so it is
        // applied in OnShown rather than here.
        _split = new SplitContainer
        {
            Dock = DockStyle.Fill,
            FixedPanel = FixedPanel.Panel1,
            SplitterWidth = 6,
            Panel1MinSize = 140
        };
        SplitContainer split = _split;

        _lstScans = new ListBox { Dock = DockStyle.Fill, Font = monospace, IntegralHeight = false };
        _lstScans.SelectedIndexChanged += (_, _) => ShowSelectedReport();
        split.Panel1.Controls.Add(_lstScans);

        _lblReportHeader = new Label
        {
            Dock = DockStyle.Top,
            Height = 34,
            TextAlign = ContentAlignment.MiddleLeft,
            Padding = new Padding(6, 0, 0, 0),
            Text = "No scans yet."
        };

        _grid = BuildGrid(monospace);

        split.Panel2.Controls.Add(_grid);
        split.Panel2.Controls.Add(_lblReportHeader);
        gbReport.Controls.Add(split);

        root.Controls.Add(gbScan, 0, 0);
        root.Controls.Add(gbReport, 0, 1);
        Controls.Add(root);

        UpdateButtons();
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        try { _split.SplitterDistance = 240; } catch { /* window too narrow to honour */ }
    }

    private static DataGridView BuildGrid(Font monospace)
    {
        var grid = new DataGridView
        {
            Dock = DockStyle.Fill,
            ReadOnly = true,
            AllowUserToAddRows = false,
            AllowUserToDeleteRows = false,
            AllowUserToResizeRows = false,
            AllowUserToOrderColumns = false,
            RowHeadersVisible = false,
            SelectionMode = DataGridViewSelectionMode.FullRowSelect,
            MultiSelect = false,
            AutoGenerateColumns = false,
            BorderStyle = BorderStyle.FixedSingle,
            BackgroundColor = SystemColors.Window,
            EnableHeadersVisualStyles = false,
            ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.DisableResizing
        };
        grid.RowsDefaultCellStyle.Font = monospace;
        grid.AlternatingRowsDefaultCellStyle.BackColor = Color.FromArgb(246, 246, 248);

        var right = new DataGridViewCellStyle { Alignment = DataGridViewContentAlignment.MiddleRight };

        void Add(string name, string header, int width, bool fill = false, DataGridViewCellStyle? style = null)
        {
            var col = new DataGridViewTextBoxColumn
            {
                Name = name,
                HeaderText = header,
                Width = width,
                SortMode = DataGridViewColumnSortMode.NotSortable, // report order is fixed by design
                AutoSizeMode = fill ? DataGridViewAutoSizeColumnMode.Fill : DataGridViewAutoSizeColumnMode.None,
                Resizable = DataGridViewTriState.True
            };
            if (style is not null) col.DefaultCellStyle = style;
            grid.Columns.Add(col);
        }

        Add("rank", "#", 50, style: right);
        Add("path", "Folder", 400, fill: true);
        Add("prev", "Last scan (GB)", 120, style: right);
        Add("curr", "This scan (GB)", 120, style: right);
        Add("growth", "Growth (GB)", 120, style: right);

        return grid;
    }

    private void LoadDrives()
    {
        _lstDrives.BeginUpdate();
        _lstDrives.Items.Clear();
        foreach (var d in DriveInfo.GetDrives())
        {
            try
            {
                if (!d.IsReady) continue;
                if (d.DriveType is not (DriveType.Fixed or DriveType.Removable)) continue;
                _lstDrives.Items.Add(new DriveItem(d));
            }
            catch
            {
                // A drive can vanish or refuse to answer between enumeration and query.
            }
        }
        _lstDrives.EndUpdate();
        if (_lstDrives.Items.Count > 0) _lstDrives.SelectedIndex = 0;
    }

    private sealed class DriveItem
    {
        public string Root { get; }
        public string Letter { get; }   // 'C:'
        private readonly string _label;

        public DriveItem(DriveInfo d)
        {
            Root = d.RootDirectory.FullName;                  // 'C:\'
            Letter = Root.TrimEnd('\\');                       // 'C:'
            string name = string.IsNullOrWhiteSpace(d.VolumeLabel) ? d.DriveType.ToString() : d.VolumeLabel;
            _label = $"{Letter}  {Truncate(name, 16),-16}  {d.TotalFreeSpace / GB,7:F1} GB free of {d.TotalSize / GB,7:F1} GB";
        }

        private static string Truncate(string s, int n) => s.Length <= n ? s : s[..(n - 1)] + "\u2026";

        public override string ToString() => _label;
    }

    // ------------------------------------------------------------------ scanning

    private void OnScanOrPauseClick(object? sender, EventArgs e)
    {
        if (_scanTask is { IsCompleted: false })
        {
            if (_pause is null) return;
            if (_pause.IsPaused) _pause.Resume();
            else _pause.Pause();
            UpdateButtons();
            return;
        }

        StartScan();
    }

    private void StartScan()
    {
        if (_lstDrives.SelectedItem is not DriveItem drive) return;

        ClearLog();
        _scanDrive = drive.Letter;
        _cts = new CancellationTokenSource();
        _pause = new PauseController();
        _scanner = new DiskScanner(_cfg, _pause, EnqueueLog);
        _elapsed = Stopwatch.StartNew();

        DateTime startedUtc = DateTime.UtcNow;
        DateTime startedLocal = DateTime.Now;

        AppendLogLine($"=== Scanning {drive.Root} at {startedLocal:yyyy-MM-dd HH:mm:ss} " +
                      $"(max depth {_cfg.MaxDepth}, min folder size {_cfg.MinFolderSizeGB:F2} GB) ===");

        var scanner = _scanner;
        var token = _cts.Token;
        string root = drive.Root;

        Task<ScanResult> task = Task.Factory.StartNew(
            () => scanner.Scan(root, token),
            token,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default);

        _scanTask = task;
        _ = AwaitScanAsync(task, startedUtc, startedLocal);
        UpdateButtons();
    }

    private async Task AwaitScanAsync(Task<ScanResult> task, DateTime startedUtc, DateTime startedLocal)
    {
        ScanResult? result = null;
        Exception? failure = null;
        bool cancelled = false;

        try
        {
            result = await task.ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            cancelled = true;
        }
        catch (Exception ex)
        {
            failure = ex;
        }

        DrainLogQueue();
        _elapsed?.Stop();

        if (cancelled)
        {
            // A half-finished walk has wrong folder sizes, which would corrupt the *next*
            // comparison as well. Discard rather than store something misleading.
            AppendLogLine($"=== Stopped by user after {Format(_elapsed)}. Nothing was saved â€” " +
                          "a partial scan cannot be compared meaningfully. ===");
        }
        else if (failure is not null)
        {
            AppendLogLine($"=== Scan failed: {failure.GetType().Name}: {failure.Message} ===");
            if (!_shuttingDown)
                MessageBox.Show(this, failure.ToString(), AppConfig.AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        else if (result is not null)
        {
            try
            {
                long scanId = _db.SaveScan(_scanDrive, startedUtc, startedLocal, _cfg, result);
                int pruned = _db.PruneOldScans(_scanDrive, _cfg.RetainScansPerDrive);

                AppendLogLine($"=== Done in {Format(_elapsed)}. {result.DirectoryCount:N0} folders, " +
                              $"{result.FileCount:N0} files, {result.TotalBytes / GB:F1} GB total. " +
                              $"{result.Folders.Count:N0} folders stored" +
                              (result.SkippedCount > 0 ? $", {result.SkippedCount:N0} unreadable" : "") +
                              (pruned > 0 ? $", {pruned} old scan(s) pruned" : "") + ". ===");

                if (!_shuttingDown) ReloadScanHistory(selectId: scanId);
            }
            catch (Exception ex)
            {
                AppendLogLine($"=== Scan finished but could not be saved: {ex.Message} ===");
                if (!_shuttingDown)
                    MessageBox.Show(this, ex.ToString(), AppConfig.AppTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        DisposeScanState();
        UpdateButtons();
        UpdateStatus();
    }

    private void OnStopClick(object? sender, EventArgs e)
    {
        if (_scanTask is not { IsCompleted: false }) return;
        _btnStop.Enabled = false;
        _btnScan.Enabled = false;
        _lblStatus.Text = "Stopping\u2026";
        _pause?.Resume();     // a paused scan must wake up to observe cancellation
        _cts?.Cancel();
    }

    private void DisposeScanState()
    {
        _cts?.Dispose();
        _cts = null;
        _pause?.Dispose();
        _pause = null;
        _scanner = null;
        _scanTask = null;
    }

    private void UpdateButtons()
    {
        bool scanning = _scanTask is { IsCompleted: false };

        if (!scanning)
        {
            _btnScan.Text = "Scan";
            _btnScan.Enabled = _lstDrives.SelectedItem is DriveItem && !_shuttingDown;
            _btnStop.Enabled = false;
            _lstDrives.Enabled = !_shuttingDown;
        }
        else
        {
            _btnScan.Text = _pause is { IsPaused: true } ? "Resume" : "Pause";
            _btnScan.Enabled = true;
            _btnStop.Enabled = true;
            _lstDrives.Enabled = false;
        }
    }

    // ------------------------------------------------------------------ log

    /// <summary>Called from the scan thread â€” must stay allocation-light and never block.</summary>
    private void EnqueueLog(string line)
    {
        if (Volatile.Read(ref _logQueueDepth) >= LogQueueCap) return;  // UI fell behind; drop
        Interlocked.Increment(ref _logQueueDepth);
        _logQueue.Enqueue(line);
    }

    private void OnUiTick(object? sender, EventArgs e)
    {
        DrainLogQueue();
        UpdateStatus();
    }

    private void DrainLogQueue()
    {
        var sb = new StringBuilder();
        int taken = 0;
        while (taken < LogDrainPerTick && _logQueue.TryDequeue(out string? line))
        {
            Interlocked.Decrement(ref _logQueueDepth);
            sb.Append(line).Append("\r\n");
            taken++;
        }
        if (taken == 0) return;

        _txtLog.AppendText(sb.ToString());
        _logLineCount += taken;
        if (_logLineCount > _cfg.LogMaxLines) TrimLog();
    }

    private void AppendLogLine(string line)
    {
        _txtLog.AppendText(line + "\r\n");
        _logLineCount++;
        if (_logLineCount > _cfg.LogMaxLines) TrimLog();
    }

    private void TrimLog()
    {
        string[] lines = _txtLog.Lines;
        int keep = _cfg.LogKeepLines;
        if (lines.Length > keep)
            _txtLog.Lines = lines[^keep..];

        _logLineCount = _txtLog.Lines.Length;
        _txtLog.SelectionStart = _txtLog.TextLength;
        _txtLog.ScrollToCaret();
    }

    private void ClearLog()
    {
        while (_logQueue.TryDequeue(out _)) Interlocked.Decrement(ref _logQueueDepth);
        _txtLog.Clear();
        _logLineCount = 0;
    }

    private void UpdateStatus()
    {
        if (_scanner is null || _elapsed is null)
        {
            if (!_shuttingDown && _scanTask is null) _lblStatus.Text = "Idle.";
            return;
        }

        string state = _pause is { IsPaused: true } ? "PAUSED" : "Scanning";
        _lblStatus.Text =
            $"{state} {_scanDrive}   elapsed {Format(_elapsed)}   " +
            $"folders {_scanner.DirectoryCount:N0}   files {_scanner.FileCount:N0}   " +
            $"seen {_scanner.BytesSeen / GB:F1} GB" +
            (_scanner.SkippedCount > 0 ? $"   unreadable {_scanner.SkippedCount:N0}" : "");
    }

    private static string Format(Stopwatch? sw) =>
        sw is null ? "00:00:00" : sw.Elapsed.ToString(@"hh\:mm\:ss", CultureInfo.InvariantCulture);

    // ------------------------------------------------------------------ report

    private void ReloadScanHistory(long? selectId)
    {
        List<ScanSummary> scans = _db.GetScans();

        _lstScans.BeginUpdate();
        _lstScans.Items.Clear();
        foreach (var s in scans) _lstScans.Items.Add(s);
        _lstScans.EndUpdate();

        if (_lstScans.Items.Count == 0)
        {
            _lblReportHeader.Text = "No scans yet â€” pick a drive above and press Scan.";
            _grid.Rows.Clear();
            return;
        }

        int index = 0;
        if (selectId is long id)
        {
            int found = scans.FindIndex(s => s.Id == id);
            if (found >= 0) index = found;
        }
        _lstScans.SelectedIndex = index;   // newest is at 0, so this defaults to the latest scan
        ShowSelectedReport();
    }

    private void ShowSelectedReport()
    {
        if (_lstScans.SelectedItem is not ScanSummary scan)
        {
            _grid.Rows.Clear();
            return;
        }

        List<ReportRow> rows = _db.GetReport(scan.Id);

        _lblReportHeader.Text = scan.PrevStartedLocal is DateTime prev
            ? $"{scan.Drive}  \u2022  {scan.StartedLocal:yyyy-MM-dd HH:mm}  vs  {prev:yyyy-MM-dd HH:mm}  \u2022  " +
              $"{rows.Count} growing folder(s)  \u2022  drive total {scan.TotalBytes / GB:F1} GB"
            : $"{scan.Drive}  \u2022  {scan.StartedLocal:yyyy-MM-dd HH:mm}  \u2022  FIRST SCAN of this drive â€” " +
              $"every folder is compared against 0, so this is a baseline, not real growth.";

        _grid.SuspendLayout();
        _grid.Rows.Clear();
        foreach (var r in rows)
        {
            int i = _grid.Rows.Add(
                r.Rank.ToString(CultureInfo.InvariantCulture),
                r.Path,
                (r.PrevBytes / GB).ToString("F1", CultureInfo.InvariantCulture),
                (r.CurrBytes / GB).ToString("F1", CultureInfo.InvariantCulture),
                (r.GrowthBytes / GB).ToString("F1", CultureInfo.InvariantCulture));

            double growthGb = r.GrowthBytes / GB;
            if (growthGb >= 5) _grid.Rows[i].Cells["growth"].Style.BackColor = Color.FromArgb(255, 205, 205);
            else if (growthGb >= 1) _grid.Rows[i].Cells["growth"].Style.BackColor = Color.FromArgb(255, 236, 200);
        }
        _grid.ResumeLayout();

        if (_grid.Rows.Count > 0) _grid.CurrentCell = _grid.Rows[0].Cells["path"];
    }

    // ------------------------------------------------------------------ shutdown

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_forceClose)
        {
            base.OnFormClosing(e);
            return;
        }

        if (_scanTask is { IsCompleted: false })
        {
            var answer = MessageBox.Show(
                this,
                $"A scan of {_scanDrive} is still running.\r\n\r\nStop it and exit? The partial scan will be discarded.",
                AppConfig.AppTitle, MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);

            if (answer != DialogResult.Yes)
            {
                e.Cancel = true;
                return;
            }

            e.Cancel = true;
            _ = StopThenCloseAsync();
            return;
        }

        _forceClose = true;
        base.OnFormClosing(e);
    }

    private async Task StopThenCloseAsync()
    {
        _shuttingDown = true;
        _btnScan.Enabled = false;
        _btnStop.Enabled = false;
        _lblStatus.Text = "Stopping scan, please wait\u2026";
        UseWaitCursor = true;

        _pause?.Resume();
        _cts?.Cancel();

        Task? task = _scanTask;
        if (task is not null)
        {
            try { await task.ConfigureAwait(true); } catch { /* cancellation is the expected outcome */ }
        }

        UseWaitCursor = false;
        _forceClose = true;
        Close();
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _uiTimer.Stop();
        _uiTimer.Tick -= OnUiTick;
        _uiTimer.Dispose();
        DisposeScanState();
        base.OnFormClosed(e);
    }
}
