using System.Diagnostics;

namespace DokiDango.NotificationListenerDotNet;

internal sealed class MainForm : Form
{
    private readonly EvidenceWriter _evidence;
    private readonly NotificationProbe _probe;
    private readonly SemaphoreSlim _operationGate = new(1, 1);
    private readonly TextBox _markerBox = new() { Text = "DOKI-NOTIFICATION-" };
    private readonly TextBox _allowedSourcesBox = new();
    private readonly TextBox _logBox = new()
    {
        Multiline = true,
        ReadOnly = true,
        ScrollBars = ScrollBars.Both,
        WordWrap = false,
        Dock = DockStyle.Fill
    };
    private readonly Label _packageLabel = new() { AutoSize = true };

    public MainForm()
    {
        Text = "Doki-Dango Windows Notification Listener .NET Harness";
        Width = 1000;
        Height = 720;
        StartPosition = FormStartPosition.CenterScreen;

        _evidence = new EvidenceWriter();
        _probe = new NotificationProbe(_evidence);
        _evidence.LineWritten += AppendEvidenceLine;

        BuildLayout();
        RecordLaunchIdentity();

        FormClosed += (_, _) =>
        {
            _probe.Dispose();
            _operationGate.Dispose();
            _evidence.Dispose();
        };
    }

    private void BuildLayout()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 1,
            RowCount = 6,
            Padding = new Padding(12)
        };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        _packageLabel.Text = "Package form: detecting...";
        root.Controls.Add(_packageLabel);

        var markerPanel = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 2
        };
        markerPanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        markerPanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        markerPanel.Controls.Add(new Label
        {
            Text = "Synthetic marker prefix:",
            AutoSize = true,
            Anchor = AnchorStyles.Left
        });
        _markerBox.Dock = DockStyle.Fill;
        markerPanel.Controls.Add(_markerBox);
        root.Controls.Add(markerPanel);

        var sourcePanel = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            ColumnCount = 2
        };
        sourcePanel.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        sourcePanel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        sourcePanel.Controls.Add(new Label
        {
            Text = "Allowed text sources (exact display names, comma-separated):",
            AutoSize = true,
            Anchor = AnchorStyles.Left
        });
        _allowedSourcesBox.Dock = DockStyle.Fill;
        sourcePanel.Controls.Add(_allowedSourcesBox);
        root.Controls.Add(sourcePanel);

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            WrapContents = true
        };

        AddButton(buttons, "1. Probe Current", () => RunAsync(() =>
        {
            _probe.ProbeCurrent();
            return Task.CompletedTask;
        }));

        AddButton(buttons, "2. Request Access", () => RunAsync(_probe.RequestAccessAsync));

        AddButton(buttons, "3. Poll", () => RunAsync(async () =>
        {
            ConfigureSyntheticFilter();
            await _probe.PollAsync();
        }));

        AddButton(buttons, "4. Start Events", () => RunAsync(() =>
        {
            ConfigureSyntheticFilter();
            _probe.StartEventListener();
            return Task.CompletedTask;
        }));

        AddButton(buttons, "Stop Events", () => RunAsync(() =>
        {
            _probe.StopEventListener();
            return Task.CompletedTask;
        }));

        AddButton(buttons, "Open Evidence Folder", () =>
        {
            OpenEvidenceFolder();
            return Task.CompletedTask;
        });

        root.Controls.Add(buttons);

        root.Controls.Add(new Label
        {
            AutoSize = true,
            Text = "Privacy: notification text is inspected only for explicitly allowed source names, and title/body are written only when the synthetic marker matches."
        });

        root.Controls.Add(_logBox);
        Controls.Add(root);
    }

    private void RecordLaunchIdentity()
    {
        var package = PackageIdentityProbe.Detect();
        _packageLabel.Text = package.PackageFullName is null
            ? $"Package form: {package.PackageForm}"
            : $"Package form: {package.PackageForm} ({package.PackageFullName})";

        _evidence.Write(
            "harness_launch",
            "success",
            new
            {
                package.PackageForm,
                package.PackageFullName,
                package.Win32Result,
                evidencePath = _evidence.EvidencePath,
                processArchitecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(),
                osArchitecture = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture.ToString()
            });
    }

    private async Task RunAsync(Func<Task> action)
    {
        if (!await _operationGate.WaitAsync(0))
        {
            MessageBox.Show(
                this,
                "Another notification probe is still running. Wait for it to finish before starting the next probe.",
                "Notification probe already running",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        try
        {
            await action();
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                this,
                $"{ex.GetType().Name}: {ex.Message}{Environment.NewLine}HRESULT: 0x{unchecked((uint)ex.HResult):X8}",
                "Notification probe error",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
        finally
        {
            _operationGate.Release();
        }
    }

    private void ConfigureSyntheticFilter()
    {
        _probe.ConfigureSyntheticFilter(GetMarker(), GetAllowedTextSources());
    }

    private string GetMarker() => _markerBox.Text;

    private IReadOnlySet<string> GetAllowedTextSources()
    {
        return _allowedSourcesBox.Text
            .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    private void AppendEvidenceLine(string line)
    {
        if (IsDisposed)
        {
            return;
        }

        void Append()
        {
            _logBox.AppendText(line);
            _logBox.AppendText(Environment.NewLine);
        }

        if (InvokeRequired)
        {
            BeginInvoke((Action)Append);
        }
        else
        {
            Append();
        }
    }

    private void OpenEvidenceFolder()
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"/select,\"{_evidence.EvidencePath}\"",
            UseShellExecute = true
        });
    }

    private static void AddButton(Control parent, string text, Func<Task> onClick)
    {
        var button = new Button
        {
            AutoSize = true,
            Text = text
        };

        button.Click += async (_, _) =>
        {
            button.Enabled = false;
            try
            {
                await onClick();
            }
            finally
            {
                button.Enabled = true;
            }
        };

        parent.Controls.Add(button);
    }
}
