-- 《断链》商城 v2：一人付（支付宝）「断链币」积分包。玩家用支付宝买断链币，在商城花断链币解锁称号。
-- 断链币余额由支付宝 / 一人付记账，本库不存余额；Edge Function「shop」用项目凭证查询（/access）和扣减（/consume）。
-- 本库只记：每次解锁的扣减请求（coin_unlocks，一人付幂等编号），每次充值入口（coin_purchases），解锁成功后写 inventory。
-- 同一玩家同一称号：一次只允许一笔扣减在途；扣减确认失败（余额不足等）后才开新的一次（attempt + 1），保证不会重复扣币。

begin;

alter table public.shop_items add column if not exists price_coins integer check (price_coins is null or price_coins between 1 and 99999);
update public.shop_items set price_coins = v.c from (values
  ('SHOP_DUANLIAN', 60), ('SHOP_ZHONGYAN', 120), ('SHOP_CHAIZHAO', 120), ('SHOP_PATRON', 300)
) as v(id, c) where shop_items.id = v.id and shop_items.price_coins is null;

create table if not exists public.coin_unlocks (
  idem_key text primary key check (idem_key ~ '^unlock-[0-9a-f-]{36}-SHOP_[A-Z0-9_]{2,24}-[0-9]{1,6}$'),
  uid uuid not null references auth.users (id) on delete cascade,
  item_id text not null references public.shop_items (id),
  attempt integer not null check (attempt >= 1),
  price integer not null check (price >= 1),
  status text not null default 'PENDING' check (status in ('PENDING', 'SUCCEEDED', 'FAILED', 'PROCESSING', 'UNKNOWN')),
  reason_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (uid, item_id, attempt)
);
alter table public.coin_unlocks enable row level security;
drop policy if exists coin_unlocks_read_own on public.coin_unlocks;
create policy coin_unlocks_read_own on public.coin_unlocks for select to authenticated using (uid = auth.uid());

create table if not exists public.coin_purchases (
  idem_key text primary key check (idem_key ~ '^buy-[0-9a-f]{8}-[0-9a-z]{6,40}$'),
  uid uuid not null references auth.users (id) on delete cascade,
  sku_id text,
  status text,
  created_at timestamptz not null default now()
);
alter table public.coin_purchases enable row level security;
drop policy if exists coin_purchases_read_own on public.coin_purchases;
create policy coin_purchases_read_own on public.coin_purchases for select to authenticated using (uid = auth.uid());

revoke all on public.coin_unlocks, public.coin_purchases from public, anon, authenticated;
grant select on public.coin_unlocks, public.coin_purchases to authenticated;
grant all on public.coin_unlocks, public.coin_purchases to service_role;

-- 开始一次解锁：返回 {action, idem_key, price, name}
--   owned    已拥有，不扣
--   resume   有一笔在途（PENDING / PROCESSING / UNKNOWN），用原编号去查或重试，不新开
--   new      新开一笔（首次，或上一笔确认失败）
create or replace function public.shop_unlock_begin(p_uid uuid, p_item text)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  v_item public.shop_items%rowtype;
  v_last public.coin_unlocks%rowtype;
  v_key text;
  v_n integer;
begin
  if p_uid is null then raise exception 'authentication required' using errcode = '42501'; end if;
  perform duanlian_private.check_limit(p_uid, 'shop_unlock', 10);
  select * into v_item from public.shop_items where id = p_item and active;
  if not found or v_item.price_coins is null then return jsonb_build_object('action', 'bad_item'); end if;
  perform pg_advisory_xact_lock(hashtext('unlock:' || p_uid::text || ':' || p_item));
  if exists (select 1 from public.inventory where uid = p_uid and item_id = p_item) then
    return jsonb_build_object('action', 'owned');
  end if;
  select * into v_last from public.coin_unlocks where uid = p_uid and item_id = p_item order by attempt desc limit 1;
  if found and v_last.status in ('PENDING', 'PROCESSING', 'UNKNOWN') then
    return jsonb_build_object('action', 'resume', 'idem_key', v_last.idem_key, 'price', v_last.price, 'name', v_item.name);
  end if;
  if found and v_last.status = 'SUCCEEDED' then   -- 扣过了但没进库存（不该发生），补发
    insert into public.inventory (uid, item_id, out_trade_no) values (p_uid, p_item, null) on conflict do nothing;
    return jsonb_build_object('action', 'owned');
  end if;
  v_n := coalesce(v_last.attempt, 0) + 1;
  v_key := 'unlock-' || p_uid::text || '-' || p_item || '-' || v_n;
  insert into public.coin_unlocks (idem_key, uid, item_id, attempt, price) values (v_key, p_uid, p_item, v_n, v_item.price_coins);
  return jsonb_build_object('action', 'new', 'idem_key', v_key, 'price', v_item.price_coins, 'name', v_item.name);
end;
$$;

-- 记录一人付的扣减结果；SUCCEEDED 时发放称号。只认已存在的编号，状态只往前走（SUCCEEDED / FAILED 是终态）
create or replace function public.shop_unlock_settle(p_key text, p_status text, p_reason text)
returns text language plpgsql security definer set search_path = pg_catalog as $$
declare
  v public.coin_unlocks%rowtype;
begin
  if p_status not in ('SUCCEEDED', 'FAILED', 'PROCESSING', 'UNKNOWN') then raise exception 'bad status'; end if;
  select * into v from public.coin_unlocks where idem_key = p_key for update;
  if not found then return 'missing'; end if;
  if v.status in ('SUCCEEDED', 'FAILED') then return v.status; end if;
  update public.coin_unlocks set status = p_status, reason_code = left(p_reason, 64), updated_at = now() where idem_key = p_key;
  if p_status = 'SUCCEEDED' then
    insert into public.inventory (uid, item_id, out_trade_no) values (v.uid, v.item_id, null) on conflict do nothing;
  end if;
  return p_status;
end;
$$;

-- 充值入口限流 + 记录
create or replace function public.shop_buy_begin(p_uid uuid, p_key text, p_sku text)
returns void language plpgsql security definer set search_path = pg_catalog as $$
begin
  if p_uid is null then raise exception 'authentication required' using errcode = '42501'; end if;
  perform duanlian_private.check_limit(p_uid, 'shop_buy', 6);
  insert into public.coin_purchases (idem_key, uid, sku_id) values (p_key, p_uid, nullif(p_sku, ''));
end;
$$;
create or replace function public.shop_buy_status(p_key text, p_status text)
returns void language sql security definer set search_path = pg_catalog as $$
  update public.coin_purchases set status = left(p_status, 16) where idem_key = p_key;
$$;
create or replace function public.shop_coins_gate(p_uid uuid)
returns void language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.check_limit(p_uid, 'shop_coins', 20);
end;
$$;

revoke all on function public.shop_unlock_begin(uuid, text), public.shop_unlock_settle(text, text, text),
  public.shop_buy_begin(uuid, text, text), public.shop_buy_status(text, text), public.shop_coins_gate(uuid) from public, anon, authenticated;
grant execute on function public.shop_unlock_begin(uuid, text), public.shop_unlock_settle(text, text, text),
  public.shop_buy_begin(uuid, text, text), public.shop_buy_status(text, text), public.shop_coins_gate(uuid) to service_role;

notify pgrst, 'reload schema';

commit;
