import { createClient } from 'jsr:@supabase/supabase-js@2';
import { worldVoiceToken } from './token.ts';

const project = Deno.env.get('SUPABASE_URL')!;
const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
const key = Deno.env.get('LIVEKIT_API_KEY') || '';
const secret = Deno.env.get('LIVEKIT_API_SECRET') || '';
const endpoint = (() => {
  try {
    const url = new URL(Deno.env.get('LIVEKIT_URL') || '');
    return url.protocol === 'wss:' && !url.username && !url.password && !url.hash && !url.search ? url.href : '';
  } catch { return ''; }
})();
const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
};
const reply = (body: unknown, status = 200) => Response.json(body, { status, headers });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers });
  if (req.method !== 'POST') return reply({ error: 'method_not_allowed' }, 405);
  if (!key || secret.length < 32 || !endpoint) return reply({ error: 'not_configured' }, 503);
  const bearer = req.headers.get('Authorization') || '';
  const jwt = /^Bearer ([^\s]+)$/i.exec(bearer)?.[1];
  if (!jwt) return reply({ error: 'login_required' }, 401);
  try {
    const userClient = createClient(project, anon, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: bearer } },
    });
    const { data, error } = await userClient.auth.getUser(jwt);
    if (error || !data.user) return reply({ error: 'login_required' }, 401);
    const { error: denied } = await userClient.rpc('dl_world_voice_authorize');
    if (denied) return reply({ error: 'voice_unavailable' }, denied.message === 'rate limit exceeded' ? 429 : 403);
    return reply({ token: await worldVoiceToken(key, secret, data.user.id), url: endpoint });
  } catch { return reply({ error: 'voice_unavailable' }, 503); }
});
