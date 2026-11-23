-- 《断链》商城 v1：爱发电收款 + 服务器发货。只卖外观（目前是称号），不影响对战。
-- 商品表 shop_items 公开可读；inventory（已拥有）和 shop_orders（订单）只能看自己的，写入全部由 Edge Function `shop`（service_role）调用 shop_grant 完成。
-- 称号：profiles.title 可以是成就 ACH_* 或商城 SHOP_*；挂 SHOP_* 称号必须已拥有（触发器检查），改接口也挂不上没买的称号。

begin;

create table if not exists public.shop_items (
  id text primary key check (id ~ '^SHOP_[A-Z0-9_]{2,24}$'),
  kind text not null default 'title' check (kind in ('title')),
  name text not null check (char_length(name) between 1 and 12),
  descr text not null default '' check (char_length(descr) <= 60),
  price_cny numeric(8, 2) not null check (price_cny > 0),
  afdian_plan_id text unique,          -- 爱发电「方案」或「商品」的 plan_id / sku_id
  afdian_url text,                     -- 购买链接（爱发电方案页）
  sort integer not null default 0,
  active boolean not null default true
);
alter table public.shop_items enable row level security;
drop policy if exists shop_items_read on public.shop_items;
create policy shop_items_read on public.shop_items for select to anon, authenticated using (active);

create table if not exists public.inventory (
  uid uuid not null references auth.users (id) on delete cascade,
  item_id text not null references public.shop_items (id),
  out_trade_no text,
  granted_at timestamptz not null default now(),
  primary key (uid, item_id)
);
alter table public.inventory enable row level security;
drop policy if exists inventory_read_own on public.inventory;
create policy inventory_read_own on public.inventory for select to authenticated using (uid = auth.uid());

create table if not exists public.shop_orders (
  out_trade_no text primary key check (out_trade_no ~ '^[0-9]{10,40}$'),
  uid uuid references auth.users (id) on delete set null,
  item_id text references public.shop_items (id),
  plan_id text,
  amount numeric(10, 2),
  remark text,
  via text not null check (via in ('webhook', 'claim')),
  status text not null check (status in ('granted', 'unclaimed', 'unknown_plan')),
  created_at timestamptz not null default now(),
  granted_at timestamptz
);
alter table public.shop_orders enable row level security;
drop policy if exists shop_orders_read_own on public.shop_orders;
create policy shop_orders_read_own on public.shop_orders for select to authenticated using (uid = auth.uid());

revoke all on public.shop_items, public.inventory, public.shop_orders from public, anon, authenticated;
grant select on public.shop_items to anon, authenticated;
grant select on public.inventory, public.shop_orders to authenticated;
grant all on public.shop_items, public.inventory, public.shop_orders to service_role;

-- 称号格式：成就或商城
alter table public.profiles drop constraint if exists profiles_cosmetics_format;
alter table public.profiles add constraint profiles_cosmetics_format check (
  avatar ~ '^CH_(JIN|LAN|YUE|YING|LING|SHUANG|LEI)$' and
  (title is null
    or title ~ '^ACH_(FIRST|WIN1|WIN10|WIN50|G100|HIT10|HIT25|LV3|LV4|FIN10|BRK10|PARRY20|BURN|AIR|SIDE|THROW|PERFECT|ALL|CPU2|ON1|ON10)$'
    or title ~ '^SHOP_[A-Z0-9_]{2,24}$')
);

-- 挂商城称号必须已拥有
create or replace function duanlian_private.check_shop_title()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
begin
  if new.title is distinct from old.title and new.title like 'SHOP\_%'
     and not exists (select 1 from public.inventory i where i.uid = new.id and i.item_id = new.title) then
    raise exception 'title not owned' using errcode = '42501';
  end if;
  return new;
end;
$$;
revoke all on function duanlian_private.check_shop_title() from public, anon, authenticated;
drop trigger if exists profiles_shop_title on public.profiles;
create trigger profiles_shop_title before update of title on public.profiles
  for each row execute function duanlian_private.check_shop_title();

-- 发货：Edge Function 先向爱发电核实订单（status = 2），再调用这里。按订单号幂等，同一订单只发一次货。
-- p_uid：玩家在游戏里填订单号领取时是本人；webhook 自动发货时为空，从买家留言里的领取码「DL + 用户 ID 前 8 位」找人。
create or replace function public.shop_grant(p_trade text, p_plan text, p_sku text, p_amount numeric, p_remark text, p_uid uuid, p_via text)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  prev public.shop_orders;
  it public.shop_items;
  u uuid := p_uid;
  code text;
  ids uuid[];
  st text;
begin
  if p_trade is null or p_trade !~ '^[0-9]{10,40}$' then return jsonb_build_object('ok', false, 'status', 'bad_trade'); end if;
  if p_via not in ('webhook', 'claim') then return jsonb_build_object('ok', false, 'status', 'bad_via'); end if;
  perform pg_advisory_xact_lock(hashtext('duanlian_shop:' || p_trade));

  select * into prev from public.shop_orders where out_trade_no = p_trade;
  if found and prev.status = 'granted' then
    return jsonb_build_object('ok', p_uid is null or prev.uid = p_uid, 'status', case when p_uid is null or prev.uid = p_uid then 'already' else 'taken' end, 'item', prev.item_id);
  end if;

  select * into it from public.shop_items where afdian_plan_id is not null and afdian_plan_id in (p_plan, p_sku) limit 1;
  if u is null then
    code := lower(substring(upper(coalesce(p_remark, '')) from 'DL([0-9A-F]{8})'));
    if code is not null then
      select array_agg(id) into ids from public.profiles where left(replace(id::text, '-', ''), 8) = code;
      if coalesce(array_length(ids, 1), 0) = 1 then u := ids[1]; end if;
    end if;
  end if;
  st := case when it.id is null then 'unknown_plan' when u is null then 'unclaimed' else 'granted' end;

  insert into public.shop_orders as o (out_trade_no, uid, item_id, plan_id, amount, remark, via, status, granted_at)
  values (p_trade, u, it.id, coalesce(nullif(p_plan, ''), p_sku), p_amount, left(coalesce(p_remark, ''), 200), p_via, st, case when st = 'granted' then now() end)
  on conflict (out_trade_no) do update set uid = excluded.uid, item_id = excluded.item_id, via = excluded.via, status = excluded.status, granted_at = excluded.granted_at;

  if st = 'granted' then
    insert into public.inventory (uid, item_id, out_trade_no) values (u, it.id, p_trade) on conflict (uid, item_id) do nothing;
  end if;
  return jsonb_build_object('ok', st = 'granted', 'status', st, 'item', it.id, 'name', it.name);
end;
$$;
revoke all on function public.shop_grant(text, text, text, numeric, text, uuid, text) from public, anon, authenticated;
grant execute on function public.shop_grant(text, text, text, numeric, text, uuid, text) to service_role;

-- 领取限流：每人每分钟最多 6 次（Edge Function 在向爱发电查单前先调用）
create or replace function public.shop_claim_gate(p_uid uuid)
returns void language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.check_limit(p_uid, 'shop_claim', 6);
end;
$$;
revoke all on function public.shop_claim_gate(uuid) from public, anon, authenticated;
grant execute on function public.shop_claim_gate(uuid) to service_role;

-- 初始商品（价格和爱发电方案由作者在后台改：update public.shop_items set afdian_plan_id = '…', afdian_url = '…', price_cny = … where id = '…'）
insert into public.shop_items (id, name, descr, price_cny, sort, active) values
  ('SHOP_DUANLIAN', '断链者', '支持作者的第一枚称号', 6, 10, true),
  ('SHOP_ZHONGYAN', '终焉行者', '把势推到尽头的人', 12, 20, true),
  ('SHOP_CHAIZHAO', '拆招宗师', '看破每一次出手', 12, 30, true),
  ('SHOP_PATRON', '断链赞助人', '感谢你让断链走得更远', 30, 40, true)
on conflict (id) do nothing;

notify pgrst, 'reload schema';

commit;
