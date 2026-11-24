// 《断链》商城 Edge Function `shop`（部署时关闭 JWT 校验：爱发电的回调不带登录信息）
//   POST /functions/v1/shop/webhook  爱发电订单回调。不信任回调内容：拿订单号回爱发电查单，确认已支付再发货。
//   POST /functions/v1/shop/claim    玩家填爱发电订单号领取（需要登录：Authorization: Bearer <用户 access token>）
// 需要的 Secrets（在 Supabase 后台 Edge Functions → Secrets 里由作者本人填写，不要提交到仓库）：
//   AFDIAN_USER_ID  爱发电开发者后台的 user_id
//   AFDIAN_TOKEN    爱发电开发者后台的 API Token
// 新充值及扣币入口关闭。历史订单的回调和补领继续由原服务验证。
import { createClient } from 'jsr:@supabase/supabase-js@2';
import { crypto } from 'jsr:@std/crypto@1';
import { encodeHex } from 'jsr:@std/encoding@1/hex';

const AF_USER = Deno.env.get('AFDIAN_USER_ID') ?? '';
const AF_TOKEN = Deno.env.get('AFDIAN_TOKEN') ?? '';
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'content-type': 'application/json' } });
const TRADE = /^[0-9]{10,40}$/;
async function md5(s: string) {
  return encodeHex(await crypto.subtle.digest('MD5', new TextEncoder().encode(s)));
}

// 向爱发电查一张订单（签名：md5(token + "params" + params + "ts" + ts + "user_id" + user_id)）
async function queryOrder(trade: string) {
  if (!AF_USER || !AF_TOKEN) throw new Error('afdian_not_configured');
  const params = JSON.stringify({ out_trade_no: trade });
  const ts = Math.floor(Date.now() / 1000);
  const sign = await md5(`${AF_TOKEN}params${params}ts${ts}user_id${AF_USER}`);
  const r = await fetch('https://afdian.com/api/open/query-order', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ user_id: AF_USER, params, ts, sign }),
  });
  const j = await r.json();
  if (j.ec !== 200) throw new Error(`afdian_${j.ec}`);
  return ((j.data && j.data.list) || []).find((o: { out_trade_no: string }) => o.out_trade_no === trade) ?? null;
}

async function grant(o: Record<string, unknown>, uid: string | null, via: 'webhook' | 'claim') {
  const sku = Array.isArray(o.sku_detail) && o.sku_detail.length ? String((o.sku_detail[0] as { sku_id?: string }).sku_id ?? '') : '';
  const { data, error } = await sb.rpc('shop_grant', {
    p_trade: String(o.out_trade_no), p_plan: String(o.plan_id ?? ''), p_sku: sku,
    p_amount: Number(o.total_amount ?? 0), p_remark: String(o.remark ?? ''), p_uid: uid, p_via: via,
  });
  if (error) throw new Error(error.message);
  return data;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, error: 'method' }, 405);
  const path = new URL(req.url).pathname;
  const body = await req.json().catch(() => ({}));

  if (path.endsWith('/webhook')) {
    const trade = body?.data?.order?.out_trade_no;
    if (typeof trade === 'string' && TRADE.test(trade)) {
      try {
        const o = await queryOrder(trade);
        if (o && o.status === 2) console.log('webhook', trade, JSON.stringify(await grant(o, null, 'webhook')));
        else console.warn('webhook: order not paid or not found', trade);
      } catch (e) { console.error('webhook', trade, String(e)); }
    }
    return json({ ec: 200, em: '' });   // 爱发电要求固定回包；没发成的订单玩家还能填订单号领取
  }

  if (path.endsWith('/claim')) {
    const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: u } = await sb.auth.getUser(token);
    if (!u?.user) return json({ ok: false, error: 'login' }, 401);
    const trade = String(body?.out_trade_no ?? '').trim();
    if (!TRADE.test(trade)) return json({ ok: false, error: 'format' }, 400);
    const gate = await sb.rpc('shop_claim_gate', { p_uid: u.user.id });
    if (gate.error) return json({ ok: false, error: 'rate' }, 429);
    try {
      const o = await queryOrder(trade);
      if (!o) return json({ ok: false, error: 'not_found' });
      if (o.status !== 2) return json({ ok: false, error: 'not_paid' });
      return json(await grant(o, u.user.id, 'claim'));
    } catch (e) {
      console.error('claim', trade, String(e));
      return json({ ok: false, error: String(e).includes('afdian_not_configured') ? 'not_configured' : 'upstream' }, 502);
    }
  }
  if (/\/(coins|buy|unlock|wx-wallet|wx-buy|wx-status|wx-unlock)$/.test(path))
    return json({ ok: false, error: 'not_configured', status: 'COMING_SOON' }, 410);
  return json({ ok: false, error: 'route' }, 404);
});
