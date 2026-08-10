using System.Text.Json;
using System.Text.Json.Serialization;

namespace DiskSizeGrowthMon;

/// <summary>
/// User-editable settings, read from <c>config.json</c> sitting next to the executable.
/// The file is created with defaults on first run.
/// </summary>
public sealed class AppConfig
{
    public const string FileName = "config.json";

    /// <summary>Window caption and message-box caption.</summary>
    public const string AppTitle = "Disk Size Growth Monitor";

    /// <summary>How many levels below the drive root are persisted. Root itself is depth 0.</summary>
    public int MaxDepth { get; set; } = 6;

    /// <summary>Folders smaller than this (recursive size) are not persisted.</summary>
    public double MinFolderSizeGB { get; set; } = 0.5;

    /// <summary>Hard cap on rows kept in a growth report.</summary>
    public int MaxReportRows { get; set; } = 300;

    /// <summary>When the live log exceeds this many lines it is trimmed to <see cref="LogKeepLines"/>.</summary>
    public int LogMaxLines { get; set; } = 1000;

    public int LogKeepLines { get; set; } = 500;

    /// <summary>Relative paths are resolved against the executable directory.</summary>
    public string DatabasePath { get; set; } = "diskgrowth.db";

    /// <summary>Full paths that are skipped entirely (prefix match, case-insensitive).</summary>
    public string[] ExcludedPaths { get; set; } = Array.Empty<string>();

    /// <summary>Scans kept per drive; older ones are deleted after each scan. 0 = keep everything.</summary>
    public int RetainScansPerDrive { get; set; } = 30;

    [JsonIgnore]
    public long MinFolderSizeBytes => (long)(MinFolderSizeGB * 1024d * 1024d * 1024d);

    [JsonIgnore]
    public string ConfigFilePath { get; private set; } = "";

    [JsonIgnore]
    public string ResolvedDatabasePath { get; private set; } = "";

    /// <summary>Non-fatal problems found while loading (shown to the user once at startup).</summary>
    [JsonIgnore]
    public List<string> LoadWarnings { get; } = new();

    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never
    };

    private static readonly JsonSerializerOptions ReadOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    public static AppConfig LoadOrCreate()
    {
        string baseDir = AppContext.BaseDirectory;
        string path = Path.Combine(baseDir, FileName);

        AppConfig cfg;
        if (File.Exists(path))
        {
            try
            {
                cfg = JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(path), ReadOptions) ?? new AppConfig();
            }
            catch (Exception ex)
            {
                cfg = new AppConfig();
                cfg.LoadWarnings.Add($"{FileName} could not be parsed ({ex.Message}). Built-in defaults are being used; the file was left untouched.");
            }
        }
        else
        {
            cfg = new AppConfig();
            try
            {
                File.WriteAllText(path, JsonSerializer.Serialize(cfg, WriteOptions));
            }
            catch (Exception ex)
            {
                cfg.LoadWarnings.Add($"{FileName} could not be created ({ex.Message}). Built-in defaults are being used.");
            }
        }

        cfg.ConfigFilePath = path;
        cfg.Normalize(baseDir);
        return cfg;
    }

    private void Normalize(string baseDir)
    {
        Clamp(nameof(MaxDepth), MaxDepth, 0, 64, v => MaxDepth = v);
        Clamp(nameof(MaxReportRows), MaxReportRows, 1, 100_000, v => MaxReportRows = v);
        Clamp(nameof(LogMaxLines), LogMaxLines, 50, 100_000, v => LogMaxLines = v);
        Clamp(nameof(RetainScansPerDrive), RetainScansPerDrive, 0, 100_000, v => RetainScansPerDrive = v);

        if (MinFolderSizeGB < 0 || double.IsNaN(MinFolderSizeGB))
        {
            LoadWarnings.Add($"{nameof(MinFolderSizeGB)} must be >= 0; using 0.");
            MinFolderSizeGB = 0;
        }

        if (LogKeepLines >= LogMaxLines || LogKeepLines < 10)
        {
            int fixedValue = Math.Max(10, LogMaxLines / 2);
            if (LogKeepLines != fixedValue)
                LoadWarnings.Add($"{nameof(LogKeepLines)} must be between 10 and {nameof(LogMaxLines)} - 1; using {fixedValue}.");
            LogKeepLines = fixedValue;
        }

        if (string.IsNullOrWhiteSpace(DatabasePath))
            DatabasePath = "diskgrowth.db";

        ResolvedDatabasePath = Path.IsPathRooted(DatabasePath)
            ? Path.GetFullPath(DatabasePath)
            : Path.GetFullPath(Path.Combine(baseDir, DatabasePath));

        ExcludedPaths = (ExcludedPaths ?? Array.Empty<string>())
            .Where(p => !string.IsNullOrWhiteSpace(p))
            .Select(p => p.Trim().TrimEnd('\\'))
            .ToArray();

        void Clamp(string name, int value, int min, int max, Action<int> set)
        {
            if (value < min || value > max)
            {
                int fixedValue = Math.Clamp(value, min, max);
                LoadWarnings.Add($"{name} must be between {min} and {max}; using {fixedValue}.");
                set(fixedValue);
            }
        }
    }
}
