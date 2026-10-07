self.addEventListener('push', (event) => {
  let payload = {};
  try { payload = event.data?.json() ?? {}; } catch { payload = { body: event.data?.text() }; }
  const kind = payload.kind ?? 'game_started';
  const options = {
    body: payload.body ?? 'Open the waitlist for an update.',
    tag: payload.tag ?? `open-gym-${kind}`,
    renotify: true,
    data: {
      url: payload.url ?? '/',
      responseId: payload.responseId ?? null,
    },
    actions: kind === 'rejoin'
      ? [
          { action: 'stay', title: 'Stay' },
          { action: 'leave', title: 'Leave' },
        ]
      : [],
  };
  event.waitUntil(self.registration.showNotification(payload.title ?? 'Open Gym', options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const base = event.notification.data?.url ?? '/';
  const responseId = event.notification.data?.responseId;
  const action = event.action;
  const target = new URL(base, self.location.origin);
  if (responseId) target.searchParams.set('response', responseId);
  if (action === 'stay' || action === 'leave') target.searchParams.set('choice', action);

  event.waitUntil((async () => {
    const windows = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    const existing = windows.find((client) => new URL(client.url).origin === self.location.origin);
    if (existing) {
      // navigate() rejects for uncontrolled windows; fall back to a new window (audit P3).
      try {
        await existing.navigate(target.href);
        return existing.focus();
      } catch {
        return clients.openWindow(target.href);
      }
    }
    return clients.openWindow(target.href);
  })());
});

