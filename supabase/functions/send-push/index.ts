import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

// Delivers queued OpenGym notifications (audit F8).
//
// Recipients and text come only from public.push_outbox, which only the database
// writes (a game starting, a rejoin prompt). This endpoint takes no input, so it
// is safe for the database (pg_net, right after each change commits), the app,
// or the once-a-minute safety-net job to call it. Previously the phone of
// whoever pressed Next Game sent each notification itself, and the function only
// accepted callers with an "admin" account flag, so most alerts were never sent.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

type OutboxRow = { id: number; user_id: string; notification: Record<string, unknown> };

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    webpush.setVapidDetails(
      Deno.env.get('VAPID_SUBJECT')!,
      Deno.env.get('VAPID_PUBLIC_KEY')!,
      Deno.env.get('VAPID_PRIVATE_KEY')!,
    );

    const { data: claimed, error: claimError } = await admin.rpc('claim_push_outbox', { p_limit: 200 });
    if (claimError) throw claimError;
    const rows = (claimed ?? []) as OutboxRow[];

    let delivered = 0;
    const expiredIds: string[] = [];
    const results: { id: number; error: string | null }[] = [];
    for (const row of rows) {
      const { data: subscriptions, error: subscriptionError } = await admin
        .from('push_subscriptions')
        .select('id, endpoint, p256dh, auth')
        .eq('user_id', row.user_id);
      if (subscriptionError) {
        results.push({ id: row.id, error: subscriptionError.message });
        continue;
      }
      let rowError: string | null = null;
      await Promise.all((subscriptions ?? []).map(async (subscription) => {
        try {
          await webpush.sendNotification({
            endpoint: subscription.endpoint,
            keys: { p256dh: subscription.p256dh, auth: subscription.auth },
          }, JSON.stringify(row.notification));
          delivered += 1;
        } catch (sendError) {
          const status = (sendError as { statusCode?: number }).statusCode;
          if (status === 404 || status === 410) expiredIds.push(subscription.id);
          else rowError = `Push delivery failed (${status ?? 'unknown'})`;
        }
      }));
      results.push({ id: row.id, error: rowError });
    }

    if (expiredIds.length) await admin.from('push_subscriptions').delete().in('id', expiredIds);
    if (results.length) {
      const { error: completeError } = await admin.rpc('complete_push_outbox', { p_results: results });
      if (completeError) throw completeError;
    }
    return Response.json({ claimed: rows.length, delivered, removedExpired: expiredIds.length }, { headers: corsHeaders });
  } catch (error) {
    console.error(error);
    return Response.json({ error: error instanceof Error ? error.message : 'Unknown error' }, { status: 500, headers: corsHeaders });
  }
});
