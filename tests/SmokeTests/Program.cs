using DiskSizeGrowthMon;

// End-to-end check of the non-UI half of the app: walk a synthetic tree, persist two scans,
// and assert the growth report says what it should. Run with:  dotnet run --project tests/SmokeTests

string work = Path.Combine(Path.GetTempPath(), "dsgm-smoke");
DeleteTree(work);
Directory.CreateDirectory(work);

// Directory.Delete(recursive) walks *into* junctions and then fails; unlink them instead.
static void DeleteTree(string dir)
{
    if (!Directory.Exists(dir)) return;
    foreach (string sub in Directory.EnumerateDirectories(dir))
    {
        var info = new DirectoryInfo(sub);
        if (info.Attributes.HasFlag(FileAttributes.ReparsePoint)) info.Delete();
        else DeleteTree(sub);
    }
    foreach (string file in Directory.EnumerateFiles(dir)) File.Delete(file);
    Directory.Delete(dir);
}

string dbPath = Path.Combine(work, "test.db");
string tree = Path.Combine(work, "tree");

const double MB = 1024d * 1024d;

void MakeFile(string relative, int megabytes)
{
    string full = Path.Combine(tree, relative);
    Directory.CreateDirectory(Path.GetDirectoryName(full)!);
    using var fs = new FileStream(full, FileMode.Create, FileAccess.Write);
    fs.SetLength(megabytes * 1024L * 1024L);
}

int failures = 0;
void Check(string what, bool ok)
{
    Console.WriteLine($"{(ok ? "PASS" : "FAIL")}  {what}");
    if (!ok) failures++;
}

// ---- scan 1 -------------------------------------------------------------
MakeFile(@"cache\a.bin", 100);
MakeFile(@"cache\deep\b.bin", 50);
MakeFile(@"logs\c.bin", 10);
MakeFile(@"stable\d.bin", 200);
MakeFile(@"very\deep\a\b\c\d\e\f\buried.bin", 300);

// A junction pointing back at its own parent must neither hang the walk nor double-count.
using (var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(
           "cmd.exe", $"/c mklink /J \"{Path.Combine(tree, "loop")}\" \"{tree}\"")
       { UseShellExecute = false, RedirectStandardOutput = true })!)
{
    p.WaitForExit();
}

var cfg = new AppConfig { MaxDepth = 3, MinFolderSizeGB = 0, MaxReportRows = 300, RetainScansPerDrive = 0 };
using var db = new Database(dbPath);
using var pause = new PauseController();

var logLines = new List<string>();
var s1 = new DiskScanner(cfg, pause, logLines.Add).Scan(tree, CancellationToken.None);

Console.WriteLine($"\nscan 1: total={s1.TotalBytes / MB:F0} MB  dirs={s1.DirectoryCount}  files={s1.FileCount}  stored={s1.Folders.Count}");
foreach (var f in s1.Folders.OrderBy(f => f.Path))
    Console.WriteLine($"   d{f.Depth} {f.SizeBytes / MB,6:F0} MB  {f.Path}");
Console.WriteLine();

Check("junction neither loops nor double-counts (total == 660 MB)", Math.Abs(s1.TotalBytes / MB - 660) < 0.5);
Check("depth cap honoured (nothing stored deeper than 3)", s1.Folders.All(f => f.Depth <= 3));
Check("deep content rolls up into its depth-3 ancestor", s1.Folders.Any(f => f.Path.EndsWith(@"very\deep\a") && Math.Abs(f.SizeBytes / MB - 300) < 0.5));
Check("root recorded at depth 0", s1.Folders.Any(f => f.Depth == 0 && f.Path == tree));
Check("log stream named the folders being scanned", logLines.Any(l => l.EndsWith(@"\cache")) && logLines.Any(l => l.EndsWith(@"\logs")));

long id1 = db.SaveScan("T:", DateTime.UtcNow.AddMinutes(-10), DateTime.Now.AddMinutes(-10), cfg, s1);
var report1 = db.GetReport(id1);
Check("first scan reports every folder as growth from 0", report1.Count == s1.Folders.Count && report1.All(r => r.PrevBytes == 0));

// ---- scan 2 -------------------------------------------------------------
MakeFile(@"cache\a.bin", 400);                     // grows by 300 MB
MakeFile(@"logs\c.bin", 10);                       // unchanged
File.Delete(Path.Combine(tree, @"stable\d.bin"));  // shrinks
MakeFile(@"brandnew\e.bin", 120);                  // did not exist before

var s2 = new DiskScanner(cfg, pause, _ => { }).Scan(tree, CancellationToken.None);
long id2 = db.SaveScan("T:", DateTime.UtcNow, DateTime.Now, cfg, s2);
var report2 = db.GetReport(id2);

Console.WriteLine("\nscan 2 growth report:");
foreach (var r in report2)
    Console.WriteLine($"   #{r.Rank,-3} {r.PrevBytes / MB,6:F0} -> {r.CurrBytes / MB,6:F0} MB  (+{r.GrowthBytes / MB,6:F0})  {r.Path}");
Console.WriteLine();

ReportRow? Row(string suffix) => report2.Cast<ReportRow?>().FirstOrDefault(r => r!.Value.Path.EndsWith(suffix));

Check("shrunk folder is absent from the growth report", Row(@"\stable") is null);
Check("unchanged folder is absent from the growth report", Row(@"\logs") is null);
Check("grown folder shows the correct delta (cache +300 MB)", Row(@"\cache") is { } c && Math.Abs(c.GrowthBytes / MB - 300) < 0.5 && Math.Abs(c.PrevBytes / MB - 150) < 0.5);
Check("brand-new folder shows growth from 0", Row(@"\brandnew") is { } n && n.PrevBytes == 0 && Math.Abs(n.GrowthBytes / MB - 120) < 0.5);
Check("ranks are 1..N with no gaps", report2.Select(r => r.Rank).SequenceEqual(Enumerable.Range(1, report2.Count)));
Check("report ordered by growth descending", report2.Select(r => r.GrowthBytes).SequenceEqual(report2.Select(r => r.GrowthBytes).OrderByDescending(x => x)));

// ---- history, retention, cancellation -----------------------------------
var scans = db.GetScans();
Check("history is newest-first", scans.Count == 2 && scans[0].Id == id2 && scans[1].Id == id1);
Check("scan 2 links back to scan 1", scans[0].PrevScanId == id1 && scans[0].PrevStartedLocal is not null);
Check("scan 1 has no predecessor", scans[1].PrevScanId is null);
Check("history label reads 'yyyy-MM-dd HH:mm D:'", scans[0].Label.EndsWith(" T:") && scans[0].Label.Length == 19);

db.PruneOldScans("T:", 1);
Check("retention keeps only the newest scan", db.GetScans().Count == 1);
Check("pruning does not damage the surviving report", db.GetReport(id2).Count == report2.Count);

using var cts = new CancellationTokenSource();
cts.Cancel();
bool threw = false;
try { new DiskScanner(cfg, pause, _ => { }).Scan(tree, cts.Token); }
catch (OperationCanceledException) { threw = true; }
Check("cancellation surfaces as OperationCanceledException", threw);

Console.WriteLine($"\n{(failures == 0 ? "ALL CHECKS PASSED" : failures + " CHECK(S) FAILED")}");
return failures == 0 ? 0 : 1;
