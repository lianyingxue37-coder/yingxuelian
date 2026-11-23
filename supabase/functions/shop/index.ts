// 《断链》商城 Edge Function `shop`（部署时关闭 JWT 校验：爱发电的回调不带登录信息）
//   POST /functions/v1/shop/webhook  爱发电订单回调。不信任回调内容：拿订单号回爱发电查单，确认已支付再发货。
//   POST /functions/v1/shop/claim    玩家填爱发电订单号领取（需要登录：Authorization: Bearer <用户 access token>）
// 需要的 Secrets（在 Supabase 后台 Edge Functions → Secrets 里由作者本人填写，不要提交到仓库）：
//   AFDIAN_USER_ID  爱发电开发者后台的 user_id
//   AFDIAN_TOKEN    爱发电开发者后台的 API Token
//   YIRENFU_API_KEY 一人付（支付宝）项目凭证 —— v3.5 起的主收款方式「断链币」积分包
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 由平台自动注入。
//
// v3.5 一人付路由（都要登录）：
//   POST /coins   {}                 → 断链币余额 + 可买的积分包
//   POST /buy     {sku_id}           → 生成支付宝购买入口（二维码图片地址 + 手机唤起链接）
//   POST /unlock  {item_id}          → 扣断链币解锁称号（一人付幂等编号保证不重复扣）
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
const YRF_KEY = Deno.env.get('YIRENFU_API_KEY') ?? '';
const YRF = 'https://ai6666.com/opcpay/api/pay/v1';

// 调一人付；返回 {status, body}。没配凭证抛 not_configured
async function yrf(method: 'GET' | 'POST', path: string, body?: unknown) {
  if (!YRF_KEY) throw new Error('not_configured');
  const r = await fetch(YRF + path, {
    method, headers: { authorization: `Bearer ${YRF_KEY}`, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(15000),
  });
  const j = await r.json().catch(() => ({}));
  if (r.status >= 500 || r.status === 401 || r.status === 429) { console.error('yirenfu', path, r.status, j?.error_code, j?.request_id); throw new Error(`yirenfu_${r.status}`); }
  return { status: r.status, body: j as Record<string, any> };
}
const packOf = (o: Record<string, any>) => ({ sku_id: String(o.sku_id), name: String(o.display_name ?? ''), price: String(o.price ?? ''), coins: Number(o.quota_amount ?? 0) });

async function coins(uid: string) {
  const [p, a] = await Promise.all([yrf('GET', '/product'), yrf('POST', '/access', { user_id: uid, amount: 0 })]);
  const opts = Array.isArray(p.body.charging_options) ? p.body.charging_options : [];
  return {
    ok: true, status: String(p.body.capability_status ?? ''),
    packs: opts.filter((o: any) => o.billing_mode === 'QUANTITY').map(packOf),
    coins: typeof a.body.remaining === 'number' ? a.body.remaining : null,
  };
}

async function buy(uid: string, sku: string) {
  const key = 'buy-' + uid.replace(/-/g, '').slice(0, 8) + '-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  const g = await sb.rpc('shop_buy_begin', { p_uid: uid, p_key: key, p_sku: sku });
  if (g.error) return { ok: false, error: 'rate' };
  const r = await yrf('POST', '/purchase', { user_id: uid, idempotency_key: key, ...(sku ? { sku_id: sku } : {}) });
  await sb.rpc('shop_buy_status', { p_key: key, p_status: String(r.body.status ?? r.status) });
  if (r.status !== 200 || r.body.status !== 'READY') { console.warn('purchase', r.status, r.body.error_code ?? r.body.reason_code); return { ok: false, error: 'purchase' }; }
  return {
    ok: true, qr: String(r.body.purchase_qr_code ?? ''), url: String(r.body.purchase_url ?? ''), expire: String(r.body.expire_time ?? ''),
    pack: r.body.charging_option ? packOf(r.body.charging_option) : null,
  };
}

async function unlock(uid: string, item: string) {
  const b = await sb.rpc('shop_unlock_begin', { p_uid: uid, p_item: item });
  if (b.error) return { ok: false, error: String(b.error.message).includes('rate') ? 'rate' : 'db' };
  const st = b.data as { action: string; idem_key?: string; price?: number; name?: string };
  if (st.action === 'owned') return { ok: true, status: 'owned' };
  if (st.action !== 'new' && st.action !== 'resume') return { ok: false, error: 'bad_item' };
  const req = { user_id: uid, idempotency_key: st.idem_key, amount: st.price, reason: `解锁称号「${st.name}」` };
  let r = st.action === 'resume' ? await yrf('POST', '/consumption', { user_id: uid, idempotency_key: st.idem_key }) : null;
  if (!r || r.status === 404) r = await yrf('POST', '/consume', req);   // 新的一笔，或者上次请求没到一人付
  if (r.status === 409) { console.error('consume conflict', r.body.error_code); return { ok: false, error: 'config' }; }
  if (r.status !== 200) return { ok: false, error: 'upstream' };
  const s = String(r.body.status);
  const fin = r.body.confirmed === true && s === 'SUCCEEDED' ? 'SUCCEEDED' : ['FAILED', 'PROCESSING', 'UNKNOWN'].includes(s) ? s : 'UNKNOWN';
  await sb.rpc('shop_unlock_settle', { p_key: st.idem_key, p_status: fin, p_reason: String(r.body.reason_code ?? '') });
  if (fin === 'SUCCEEDED') return { ok: true, status: 'unlocked', remaining: r.body.remaining ?? null };
  if (fin === 'FAILED') return { ok: false, error: String(r.body.reason_code ?? '').includes('INSUFFICIENT') ? 'coins' : 'failed' };
  return { ok: false, error: 'pending' };   // 结果待确认：再点一次会用原编号去查，不会重复扣
}

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
  if (/\/(coins|buy|unlock)$/.test(path)) {
    const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: u } = await sb.auth.getUser(token);
    if (!u?.user) return json({ ok: false, error: 'login' }, 401);
    const uid = u.user.id;
    try {
      if (path.endsWith('/coins')) {
        const g = await sb.rpc('shop_coins_gate', { p_uid: uid });
        if (g.error) return json({ ok: false, error: 'rate' }, 429);
        return json(await coins(uid));
      }
      if (path.endsWith('/buy')) {
        const sku = String(body?.sku_id ?? '');
        if (sku.length > 128) return json({ ok: false, error: 'format' }, 400);
        return json(await buy(uid, sku));
      }
      const item = String(body?.item_id ?? '');
      if (!/^SHOP_[A-Z0-9_]{2,24}$/.test(item)) return json({ ok: false, error: 'format' }, 400);
      return json(await unlock(uid, item));
    } catch (e) {
      console.error(path, String(e));
      return json({ ok: false, error: String(e).includes('not_configured') ? 'not_configured' : 'upstream' }, 502);
    }
  }
  return json({ ok: false, error: 'route' }, 404);
});
