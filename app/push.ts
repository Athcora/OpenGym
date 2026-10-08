import { VAPID_PUBLIC_KEY } from './env';
import { supabase } from './supabase';

function decodeBase64Url(value: string) {
  const padding = '='.repeat((4 - (value.length % 4)) % 4);
  const base64 = (value + padding).replace(/-/g, '+').replace(/_/g, '/');
  return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
}

export function pushSupported() {
  return typeof window !== 'undefined'
    && typeof navigator !== 'undefined'
    && 'serviceWorker' in navigator
    && 'PushManager' in window
    && 'Notification' in window;
}

export async function enablePush() {
  if (!pushSupported()) throw new Error('Push notifications are not supported on this browser.');
  const publicKey = VAPID_PUBLIC_KEY;
  if (!publicKey) throw new Error('The app administrator still needs to add the VAPID public key.');

  const permission = await Notification.requestPermission();
  if (permission !== 'granted') throw new Error('Notification permission was not granted.');

  // navigator.serviceWorker.ready never resolves without a registration, which
  // froze the page on /g/<slug> entry links (audit P1). Register if needed and
  // time out instead of hanging.
  if (!(await navigator.serviceWorker.getRegistration())) await navigator.serviceWorker.register('/sw.js');
  const registration = await Promise.race([
    navigator.serviceWorker.ready,
    new Promise<never>((_, reject) => setTimeout(() => reject(new Error('Notifications are still starting up. Please try again in a moment.')), 10_000)),
  ]);
  const existing = await registration.pushManager.getSubscription();
  const subscription = existing ?? await registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: decodeBase64Url(publicKey),
  });

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('Sign in or continue as a guest before enabling notifications.');

  const json = subscription.toJSON();
  const { error } = await supabase.from('push_subscriptions').upsert({
    user_id: user.id,
    endpoint: json.endpoint,
    p256dh: json.keys?.p256dh,
    auth: json.keys?.auth,
    user_agent: navigator.userAgent,
    updated_at: new Date().toISOString(),
  }, { onConflict: 'endpoint' });
  if (error) throw error;
}
