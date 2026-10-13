use windows::{
    Foundation::TypedEventHandler,
    UI::Notifications::Management::{
        UserNotificationListener, UserNotificationListenerAccessStatus,
    },
    UI::Notifications::{
        KnownNotificationBindings, NotificationKinds, UserNotification,
        UserNotificationChangedEventArgs, UserNotificationChangedKind,
    },
};

const WINDOWS_TO_UNIX_EPOCH_TICKS: i64 = 116_444_736_000_000_000;
const TICKS_PER_MILLISECOND: i64 = 10_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotificationAccess {
    Allowed,
    Denied,
    Unspecified,
    Unknown,
}

impl NotificationAccess {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Allowed => "Allowed",
            Self::Denied => "Denied",
            Self::Unspecified => "Unspecified",
            Self::Unknown => "Unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotificationChangeKind {
    Added,
    Removed,
    Unknown,
}

impl NotificationChangeKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Added => "Added",
            Self::Removed => "Removed",
            Self::Unknown => "Unknown",
        }
    }
}

#[derive(Debug, Clone)]
pub struct NotificationSnapshot {
    pub id: u32,
    pub app_display_name: String,
    pub creation_time_unix_ms: i64,
    pub text_elements: Vec<String>,
    pub text_available: bool,
}

#[derive(Debug, Clone)]
pub struct NotificationEvent {
    pub kind: NotificationChangeKind,
    pub id: u32,
    pub snapshot: Option<NotificationSnapshot>,
}

pub struct NotificationListener {
    inner: UserNotificationListener,
}

impl NotificationListener {
    pub fn current() -> windows::core::Result<Self> {
        Ok(Self {
            inner: UserNotificationListener::Current()?,
        })
    }

    pub fn access_status(&self) -> windows::core::Result<NotificationAccess> {
        Ok(map_access(self.inner.GetAccessStatus()?))
    }

    pub fn request_access(&self) -> windows::core::Result<NotificationAccess> {
        Ok(map_access(self.inner.RequestAccessAsync()?.join()?))
    }

    pub fn poll(&self) -> windows::core::Result<Vec<NotificationSnapshot>> {
        let notifications = self
            .inner
            .GetNotificationsAsync(NotificationKinds::Toast)?
            .join()?;
        let size = notifications.Size()?;
        let mut snapshots = Vec::with_capacity(size as usize);

        for index in 0..size {
            snapshots.push(snapshot(&notifications.GetAt(index)?)?);
        }

        Ok(snapshots)
    }

    pub fn subscribe<F>(&self, callback: F) -> windows::core::Result<NotificationSubscription>
    where
        F: Fn(NotificationEvent) + Send + Sync + 'static,
    {
        let handler =
            TypedEventHandler::<UserNotificationListener, UserNotificationChangedEventArgs>::new(
                move |sender, args| {
                    if let (Some(sender), Some(args)) = (sender.as_ref(), args.as_ref()) {
                        let kind = map_change_kind(args.ChangeKind()?);
                        let id = args.UserNotificationId()?;
                        let event_snapshot = if kind == NotificationChangeKind::Added {
                            sender
                                .GetNotification(id)
                                .ok()
                                .and_then(|value| snapshot(&value).ok())
                        } else {
                            None
                        };

                        callback(NotificationEvent {
                            kind,
                            id,
                            snapshot: event_snapshot,
                        });
                    }

                    Ok(())
                },
            );

        let token = self.inner.NotificationChanged(&handler)?;

        Ok(NotificationSubscription {
            listener: self.inner.clone(),
            token,
            _handler: handler,
        })
    }
}

pub struct NotificationSubscription {
    listener: UserNotificationListener,
    token: i64,
    _handler: TypedEventHandler<UserNotificationListener, UserNotificationChangedEventArgs>,
}

impl Drop for NotificationSubscription {
    fn drop(&mut self) {
        let _ = self.listener.RemoveNotificationChanged(self.token);
    }
}

fn map_access(status: UserNotificationListenerAccessStatus) -> NotificationAccess {
    if status == UserNotificationListenerAccessStatus::Allowed {
        NotificationAccess::Allowed
    } else if status == UserNotificationListenerAccessStatus::Denied {
        NotificationAccess::Denied
    } else if status == UserNotificationListenerAccessStatus::Unspecified {
        NotificationAccess::Unspecified
    } else {
        NotificationAccess::Unknown
    }
}

fn map_change_kind(kind: UserNotificationChangedKind) -> NotificationChangeKind {
    if kind == UserNotificationChangedKind::Added {
        NotificationChangeKind::Added
    } else if kind == UserNotificationChangedKind::Removed {
        NotificationChangeKind::Removed
    } else {
        NotificationChangeKind::Unknown
    }
}

fn snapshot(notification: &UserNotification) -> windows::core::Result<NotificationSnapshot> {
    let app_display_name = notification
        .AppInfo()
        .and_then(|app| app.DisplayInfo())
        .and_then(|display| display.DisplayName())
        .map(|value| value.to_string_lossy())
        .unwrap_or_else(|_| "<unavailable>".to_string());

    let (text_elements, text_available) = match extract_text(notification) {
        Ok(values) => (values, true),
        Err(_) => (Vec::new(), false),
    };

    Ok(NotificationSnapshot {
        id: notification.Id()?,
        app_display_name,
        creation_time_unix_ms: creation_unix_ms(notification)?,
        text_elements,
        text_available,
    })
}

fn extract_text(notification: &UserNotification) -> windows::core::Result<Vec<String>> {
    let binding_name = KnownNotificationBindings::ToastGeneric()?;
    let binding = notification
        .Notification()?
        .Visual()?
        .GetBinding(&binding_name)?;
    let elements = binding.GetTextElements()?;
    let size = elements.Size()?;
    let mut values = Vec::with_capacity(size as usize);

    for index in 0..size {
        values.push(elements.GetAt(index)?.Text()?.to_string_lossy());
    }

    Ok(values)
}

fn creation_unix_ms(notification: &UserNotification) -> windows::core::Result<i64> {
    let ticks = notification.CreationTime()?.UniversalTime;
    Ok((ticks - WINDOWS_TO_UNIX_EPOCH_TICKS) / TICKS_PER_MILLISECOND)
}
