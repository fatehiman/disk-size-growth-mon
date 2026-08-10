namespace DiskSizeGrowthMon;

/// <summary>
/// Cooperative pause gate. The scan thread calls <see cref="Wait"/> in its inner loop;
/// the UI thread flips the gate. Cheap when running (one volatile read per entry).
/// </summary>
public sealed class PauseController : IDisposable
{
    private readonly ManualResetEventSlim _gate = new(initialState: true);

    public bool IsPaused => !_gate.IsSet;

    public void Pause() => _gate.Reset();

    public void Resume() => _gate.Set();

    public void Wait(CancellationToken ct)
    {
        if (_gate.IsSet) return;
        _gate.Wait(ct);
    }

    public void Dispose() => _gate.Dispose();
}
