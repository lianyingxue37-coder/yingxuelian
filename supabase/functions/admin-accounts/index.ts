import { createClient } from 'jsr:@supabase/supabase-js@2';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false, autoRefreshToken: false },
  global: {
    fetch: (input, init) => {
      const timeout = AbortSignal.timeout(10000);
      return fetch(input, { ...init, signal: init?.signal ? AbortSignal.any([timeout, init.signal]) : timeout });
    },
  },
});
const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
};
const reply = (status: number, body: object) => Response.json(body, { status, headers });
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (request.method !== 'POST') return reply(405, { error: 'method_not_allowed' });
  const token = request.headers.get('authorization')?.match(/^Bearer ([^ ]+)$/i)?.[1];
  if (!token) return reply(401, { error: 'authentication_required' });

  try {
    const { data: { user }, error: authError } = await admin.auth.getUser(token);
    if (authError || !user) return reply(401, { error: 'authentication_required' });

    const input = await request.json().catch(() => null);
    const target = input?.target;
    const action = input?.action;
    const reason = typeof input?.reason === 'string' ? input.reason.trim() : '';
    if (typeof target !== 'string' || !uuid.test(target) || !['ban', 'unban'].includes(action) ||
      reason.length < 1 || Array.from(reason).length > 240) {
      return reply(400, { error: 'invalid_account_action' });
    }

    const { data: id, error: beginError } = await admin.rpc('dl_admin_account_begin', {
      p_actor: user.id, p_target: target, p_action: action, p_reason: reason,
    });
    if (beginError) {
      const messages: Record<string, number> = {
        admin_required: 403, protected_account: 403, account_not_found: 404,
        account_state_changed: 409, account_action_in_progress: 409, 'rate limit exceeded': 429,
      };
      const status = messages[beginError.message];
      if (status) return reply(status, { error: beginError.message });
      console.error('admin account begin', beginError.code);
      return reply(503, { error: 'admin_unavailable' });
    }

    let outcome = 'uncertain';
    try {
      const { error } = await admin.auth.admin.updateUserById(target, {
        ban_duration: action === 'ban' ? '876000h' : 'none',
      });
      if (!error) outcome = 'done';
      else if (error.status && error.status >= 400 && error.status < 500) outcome = 'failed';
    } catch {
      // 请求超时后无法推断 Auth 是否已执行。保留待核对状态。
    }

    const { error: finishError } = await admin.rpc('dl_admin_account_finish', { p_id: id, p_outcome: outcome });
    if (finishError) {
      console.error('admin audit finish', id, finishError.code);
      return reply(503, { error: 'action_uncertain' });
    }
    if (outcome === 'uncertain') return reply(503, { error: 'action_uncertain' });
    if (outcome === 'failed') return reply(502, { error: 'auth_update_failed' });
    return reply(200, { ok: true });
  } catch {
    return reply(503, { error: 'admin_unavailable' });
  }
});
