using Windows.UI.Notifications;
using Windows.UI.Notifications.Management;

namespace DokiDango.A1Harness;

internal sealed class NotificationProbe : IDisposable
{
    private readonly EvidenceWriter _evidence;
    private readonly object _filterGate = new();
    private UserNotificationListener? _listener;
    private bool _eventSubscribed;
    private string _marker = "DOKI-A1-";
    private HashSet<string> _allowedTextSources = new(StringComparer.OrdinalIgnoreCase);

    public NotificationProbe(EvidenceWriter evidence)
    {
        _evidence = evidence;
    }

    public void ConfigureSyntheticFilter(string marker, IEnumerable<string> allowedTextSources)
    {
        lock (_filterGate)
        {
            _marker = marker.Trim();
            _allowedTextSources = allowedTextSources
                .Where(source => !string.IsNullOrWhiteSpace(source))
                .Select(source => source.Trim())
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
        }

        _evidence.Write(
            "synthetic_filter.configure",
            "success",
            new
            {
                markerConfigured = _marker.Length > 0,
                allowedTextSourceCount = _allowedTextSources.Count
            });
    }

    public void ProbeCurrent()
    {
        try
        {
            _listener = UserNotificationListener.Current;
            var package = PackageIdentityProbe.Detect();

            _evidence.Write(
                "UserNotificationListener.Current",
                "success",
                new
                {
                    package.PackageForm,
                    package.PackageFullName,
                    package.Win32Result,
                    accessStatus = _listener.GetAccessStatus().ToString()
                });
        }
        catch (Exception ex)
        {
            _evidence.Write("UserNotificationListener.Current", "exception", exception: ex);
            throw;
        }
    }

    public async Task RequestAccessAsync()
    {
        try
        {
            var listener = GetListener();
            var before = listener.GetAccessStatus();
            var result = await listener.RequestAccessAsync();
            var after = listener.GetAccessStatus();

            _evidence.Write(
                "RequestAccessAsync",
                "success",
                new
                {
                    before = before.ToString(),
                    result = result.ToString(),
                    after = after.ToString()
                });
        }
        catch (Exception ex)
        {
            _evidence.Write("RequestAccessAsync", "exception", exception: ex);
            throw;
        }
    }

    public async Task PollAsync()
    {
        try
        {
            var listener = GetListener();
            var access = listener.GetAccessStatus();

            if (access != UserNotificationListenerAccessStatus.Allowed)
            {
                _evidence.Write(
                    "GetNotificationsAsync",
                    "skipped",
                    new { accessStatus = access.ToString(), reason = "access_not_allowed" });
                return;
            }

            var started = DateTimeOffset.UtcNow;
            var notifications = await listener.GetNotificationsAsync(NotificationKinds.Toast);
            var finished = DateTimeOffset.UtcNow;

            _evidence.Write(
                "GetNotificationsAsync",
                "success",
                new
                {
                    count = notifications.Count,
                    startedUtc = started,
                    finishedUtc = finished,
                    elapsedMs = (finished - started).TotalMilliseconds
                });

            foreach (var notification in notifications)
            {
                _evidence.Write(
                    "notification_snapshot",
                    "observed",
                    Summarize(notification));
            }
        }
        catch (Exception ex)
        {
            _evidence.Write("GetNotificationsAsync", "exception", exception: ex);
            throw;
        }
    }

    public void StartEventListener()
    {
        try
        {
            var listener = GetListener();

            if (_eventSubscribed)
            {
                _evidence.Write("NotificationChanged.subscribe", "already_subscribed");
                return;
            }

            listener.NotificationChanged += OnNotificationChanged;
            _eventSubscribed = true;
            _evidence.Write(
                "NotificationChanged.subscribe",
                "success",
                new { accessStatus = listener.GetAccessStatus().ToString() });
        }
        catch (Exception ex)
        {
            _evidence.Write("NotificationChanged.subscribe", "exception", exception: ex);
            throw;
        }
    }

    public void StopEventListener()
    {
        if (!_eventSubscribed || _listener is null)
        {
            _evidence.Write("NotificationChanged.unsubscribe", "not_subscribed");
            return;
        }

        _listener.NotificationChanged -= OnNotificationChanged;
        _eventSubscribed = false;
        _evidence.Write("NotificationChanged.unsubscribe", "success");
    }

    private void OnNotificationChanged(
        UserNotificationListener sender,
        UserNotificationChangedEventArgs args)
    {
        try
        {
            _evidence.Write(
                "NotificationChanged.event",
                "observed",
                new
                {
                    changeKind = args.ChangeKind.ToString(),
                    userNotificationId = args.UserNotificationId
                });

            if (args.ChangeKind == UserNotificationChangedKind.Added)
            {
                try
                {
                    var notification = sender.GetNotification(args.UserNotificationId);

                    if (notification is not null)
                    {
                        _evidence.Write(
                            "notification_event_snapshot",
                            "observed",
                            Summarize(notification));
                    }
                }
                catch (Exception snapshotException)
                {
                    _evidence.Write(
                        "notification_event_snapshot",
                        "exception",
                        new { userNotificationId = args.UserNotificationId },
                        snapshotException);
                }
            }
        }
        catch (Exception ex)
        {
            _evidence.Write("NotificationChanged.event", "exception", exception: ex);
        }
    }

    private object Summarize(UserNotification notification)
    {
        string appDisplayName;

        try
        {
            appDisplayName = notification.AppInfo.DisplayInfo.DisplayName;
        }
        catch
        {
            appDisplayName = "<unavailable>";
        }

        string marker;
        bool sourceAllowsText;

        lock (_filterGate)
        {
            marker = _marker;
            sourceAllowsText = _allowedTextSources.Contains(appDisplayName);
        }

        if (!sourceAllowsText)
        {
            return new
            {
                appDisplayName,
                notification.Id,
                notification.CreationTime,
                textInspection = "not_requested"
            };
        }

        try
        {
            var binding = notification.Notification.Visual.GetBinding(KnownNotificationBindings.ToastGeneric);
            var textElements = binding?.GetTextElements().Select(element => element.Text).ToArray()
                ?? Array.Empty<string>();

            var markerMatched =
                marker.Length > 0 &&
                textElements.Any(text => text.Contains(marker, StringComparison.Ordinal));

            return new
            {
                appDisplayName,
                notification.Id,
                notification.CreationTime,
                textInspection = "allowed_source",
                textElementCount = textElements.Length,
                markerMatched,
                title = markerMatched ? textElements.FirstOrDefault() : null,
                body = markerMatched ? string.Join(Environment.NewLine, textElements.Skip(1)) : null
            };
        }
        catch (Exception ex)
        {
            return new
            {
                appDisplayName,
                notification.Id,
                notification.CreationTime,
                textInspection = "exception",
                hresult = $"0x{unchecked((uint)ex.HResult):X8}",
                exceptionType = ex.GetType().FullName,
                exceptionMessage = ex.Message
            };
        }
    }

    private UserNotificationListener GetListener()
    {
        _listener ??= UserNotificationListener.Current;
        return _listener;
    }

    public void Dispose()
    {
        if (_eventSubscribed && _listener is not null)
        {
            _listener.NotificationChanged -= OnNotificationChanged;
            _eventSubscribed = false;
        }
    }
}
