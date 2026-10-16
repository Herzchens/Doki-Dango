using System.Text.Json;

namespace DokiDango.A1Harness;

internal sealed class EvidenceWriter : IDisposable
{
    private readonly object _gate = new();
    private readonly StreamWriter _writer;

    public EvidenceWriter()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Doki-Dango",
            "A1",
            "evidence");

        Directory.CreateDirectory(directory);
        EvidencePath = Path.Combine(directory, $"a1-{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}.jsonl");
        _writer = new StreamWriter(
            new FileStream(EvidencePath, FileMode.CreateNew, FileAccess.Write, FileShare.Read),
            new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false))
        {
            AutoFlush = true
        };
    }

    public string EvidencePath { get; }

    public event Action<string>? LineWritten;

    public void Write(string operation, string outcome, object? data = null, Exception? exception = null)
    {
        var record = new
        {
            timestampUtc = DateTimeOffset.UtcNow,
            phase = "A1",
            operation,
            outcome,
            hresult = exception is null ? null : $"0x{unchecked((uint)exception.HResult):X8}",
            exceptionType = exception?.GetType().FullName,
            exceptionMessage = exception?.Message,
            data
        };

        var line = JsonSerializer.Serialize(record);

        lock (_gate)
        {
            _writer.WriteLine(line);
        }

        LineWritten?.Invoke(line);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _writer.Dispose();
        }
    }
}
