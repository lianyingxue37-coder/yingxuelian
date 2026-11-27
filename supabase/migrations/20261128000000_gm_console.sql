-- 《断链》管理后台（GM 后台，v1）：admin/index.html 用管理员的游戏账号登录，所有操作走下面这些 gm_* 函数。
-- 权限：只有 duanlian_private.gm_admins 里的账号能调用；每个函数开头都先 gm_require(auth.uid())。
-- 所有写操作都记到 duanlian_private.gm_log（谁、对谁、做了什么、原因）。
-- 封号 / 踢下线直接改 auth.users.banned_until、删 auth.sessions（Supabase 的 postgres 角色有权限），不需要 service_role 密钥。
-- 与 Codex 的 admin_* / dl_admin_* 对象互不依赖。

begin;

-- 仓库补齐：生产库已有的「组合包」商品类型（v3.7 七人立绘）
alter table public.shop_items drop constraint if exists shop_items_kind_check;
alter table public.shop_items add constraint shop_items_kind_check check (kind in ('title', 'bundle'));
insert into public.shop_items (id, kind, name, descr, price_cny, sort, active)
values ('SHOP_PORTRAITS', 'bundle', '全角色立绘组合包', '七名角色的原创新版立绘', 18, 50, true)
on conflict (id) do nothing;

create table if not exists duanlian_private.gm_admins (
  uid uuid primary key references auth.users (id) on delete cascade,
  role text not null default 'admin' check (role in ('owner', 'admin')),
  added_at timestamptz not null default now(),
  added_by uuid
);
create table if not exists duanlian_private.gm_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  actor uuid,
  actor_name text,
  action text not null,
  target uuid,
  target_name text,
  reason text,
  detail jsonb not null default '{}'
);
create index if not exists gm_log_target on duanlian_private.gm_log (target, at desc);
revoke all on duanlian_private.gm_admins, duanlian_private.gm_log from public, anon, authenticated;

-- 公告：游戏标题页显示；玩家只读当前生效的
create table if not exists public.announcements (
  id bigserial primary key,
  body text not null check (char_length(btrim(body)) between 1 and 300),
  level text not null default 'info' check (level in ('info', 'warn')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid
);
alter table public.announcements enable row level security;
drop policy if exists announcements_read_live on public.announcements;
create policy announcements_read_live on public.announcements for select to anon, authenticated
  using (active and starts_at <= now() and (ends_at is null or ends_at > now()));
revoke all on public.announcements from public, anon, authenticated;
grant select on public.announcements to anon, authenticated;

-- 首个站长：已经在旧后台名单里的账号（生产库里是作者本人）。以后在后台「管理员」页增删
do $$
begin
  if to_regclass('duanlian_private.admin_members') is not null
     and not exists (select 1 from duanlian_private.gm_admins) then
    execute 'insert into duanlian_private.gm_admins (uid, role) select uid, ''owner'' from duanlian_private.admin_members on conflict do nothing';
  end if;
end $$;

-- ---------- 内部工具 ----------
create or replace function duanlian_private.gm_require(p_uid uuid, p_owner boolean default false)
returns text language plpgsql stable set search_path = pg_catalog as $$
declare v_name text; v_role text;
begin
  select g.role, coalesce(p.username, '?') into v_role, v_name
  from duanlian_private.gm_admins g left join public.profiles p on p.id = g.uid where g.uid = p_uid;
  if v_role is null or (p_owner and v_role <> 'owner') then raise exception 'not_admin' using errcode = '42501'; end if;
  return v_name;
end;
$$;
create or replace function duanlian_private.gm_reason(p text)
returns text language plpgsql immutable set search_path = pg_catalog as $$
begin
  if p is null or char_length(btrim(p)) not between 1 and 200 then raise exception 'reason_required' using errcode = '22023'; end if;
  return btrim(p);
end;
$$;
create or replace function duanlian_private.gm_write(p_action text, p_target uuid, p_reason text, p_detail jsonb)
returns void language plpgsql set search_path = pg_catalog as $$
declare v_actor uuid := auth.uid();
begin
  insert into duanlian_private.gm_log (actor, actor_name, action, target, target_name, reason, detail)
  values (v_actor, (select username from public.profiles where id = v_actor), p_action, p_target,
          (select username from public.profiles where id = p_target), p_reason, coalesce(p_detail, '{}'));
end;
$$;
-- 改别人的号之前：账号存在，且不是管理员（管理员之间不能互相封号 / 改资料，站长除外）
create or replace function duanlian_private.gm_target(p_target uuid)
returns void language plpgsql stable set search_path = pg_catalog as $$
begin
  if not exists (select 1 from public.profiles where id = p_target) then raise exception 'player_not_found'; end if;
  if exists (select 1 from duanlian_private.gm_admins where uid = p_target)
     and not exists (select 1 from duanlian_private.gm_admins where uid = auth.uid() and role = 'owner') then
    raise exception 'protected_admin' using errcode = '42501';
  end if;
end;
$$;

-- ---------- 读 ----------
create or replace function public.gm_me()
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
declare v_name text := duanlian_private.gm_require(auth.uid());
begin
  return jsonb_build_object('uid', auth.uid(), 'username', v_name,
    'role', (select role from duanlian_private.gm_admins where uid = auth.uid()));
end;
$$;

create or replace function public.gm_overview()
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.gm_require(auth.uid());
  return jsonb_build_object(
    'players', (select count(*) from public.profiles),
    'new_1d', (select count(*) from public.profiles where created_at > now() - interval '1 day'),
    'new_7d', (select count(*) from public.profiles where created_at > now() - interval '7 days'),
    'active_1d', (select count(*) from auth.users where last_sign_in_at > now() - interval '1 day'),
    'active_7d', (select count(*) from auth.users where last_sign_in_at > now() - interval '7 days'),
    'banned', (select count(*) from auth.users where banned_until > now()),
    'matches_1d', (select count(*) from public.matches where created_at > now() - interval '1 day'),
    'online_1d', (select count(*) from duanlian_private.games where opened_at > now() - interval '1 day'),
    'rooms_live', (select count(*) from duanlian_private.rooms where host_until > now()),
    'queue_live', (select count(*) from duanlian_private.mm_queue where seen_at > now() - interval '30 seconds'),
    'items_owned', (select count(*) from public.inventory),
    'announcements', (select count(*) from public.announcements where active and starts_at <= now() and (ends_at is null or ends_at > now())),
    'signups', (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'n', n) order by d), '[]') from (
      select date_trunc('day', created_at)::date d, count(*) n from public.profiles
      where created_at > now() - interval '14 days' group by 1) s),
    'games', (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'n', n) order by d), '[]') from (
      select date_trunc('day', created_at)::date d, count(*) n from public.matches
      where created_at > now() - interval '14 days' group by 1) s),
    'recent', (select coalesce(jsonb_agg(x order by x.at desc), '[]') from (
      select at, actor_name, action, target_name, reason from duanlian_private.gm_log order by at desc limit 8) x)
  );
end;
$$;

create or replace function public.gm_players(p_query text default '', p_sort text default 'new', p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
declare v_q text := lower(btrim(coalesce(p_query, '')));
begin
  perform duanlian_private.gm_require(auth.uid());
  return jsonb_build_object(
    'total', (select count(*) from public.profiles p where v_q = '' or p.username like '%' || v_q || '%'
              or lower(p.nickname) like '%' || v_q || '%' or p.id::text = v_q),
    'rows', (select coalesce(jsonb_agg(r), '[]') from (
      select p.id, p.username, p.nickname, p.avatar, p.title, p.rating, p.created_at,
        u.last_sign_in_at, u.banned_until > now() as banned, u.banned_until,
        coalesce((p.stats ->> 'games')::int, 0) as games, coalesce((p.stats ->> 'onG')::int, 0) as online_games,
        exists (select 1 from duanlian_private.gm_admins g where g.uid = p.id) as admin,
        (select count(*) from public.inventory i where i.uid = p.id) as items
      from public.profiles p left join auth.users u on u.id = p.id
      where v_q = '' or p.username like '%' || v_q || '%' or lower(p.nickname) like '%' || v_q || '%' or p.id::text = v_q
      order by case when p_sort = 'rating' then p.rating end desc nulls last,
               case when p_sort = 'active' then u.last_sign_in_at end desc nulls last,
               case when p_sort = 'games' then coalesce((p.stats ->> 'games')::int, 0) end desc nulls last,
               p.created_at desc
      offset greatest(coalesce(p_offset, 0), 0) limit 50) r));
end;
$$;

create or replace function public.gm_player(p_target uuid)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
declare v jsonb;
begin
  perform duanlian_private.gm_require(auth.uid());
  select to_jsonb(p) || jsonb_build_object(
      'last_sign_in_at', u.last_sign_in_at, 'banned_until', u.banned_until, 'banned', u.banned_until > now(),
      'real_email', case when u.email like '%@players.duanlian.game' then null else u.email end,
      'sessions', (select count(*) from auth.sessions s where s.user_id = p.id),
      'admin', (select role from duanlian_private.gm_admins g where g.uid = p.id))
    into v from public.profiles p left join auth.users u on u.id = p.id where p.id = p_target;
  if v is null then raise exception 'player_not_found'; end if;
  return v || jsonb_build_object(
    'inventory', (select coalesce(jsonb_agg(jsonb_build_object('id', i.item_id, 'name', s.name, 'kind', s.kind, 'at', i.granted_at,
        'source', case when i.out_trade_no is not null then 'afdian'
                       when exists (select 1 from public.coin_unlocks c where c.uid = i.uid and c.item_id = i.item_id and c.status = 'SUCCEEDED') then 'coins'
                       else 'gm' end) order by s.sort), '[]')
      from public.inventory i join public.shop_items s on s.id = i.item_id where i.uid = p_target),
    'matches', (select coalesce(jsonb_agg(m order by m.created_at desc), '[]') from (
      select id, mode, my_char, opp_char, opp_name, result, rounds, max_hits, created_at, verified
      from public.matches where user_id = p_target order by created_at desc limit 30) m),
    'friends', (select count(*) from public.friendships f where f.status = 'accepted' and p_target in (f.requester, f.addressee)),
    'log', (select coalesce(jsonb_agg(l order by l.at desc), '[]') from (
      select at, actor_name, action, reason, detail from duanlian_private.gm_log where target = p_target order by at desc limit 30) l));
end;
$$;

create or replace function public.gm_catalog()
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.gm_require(auth.uid());
  return (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'kind', s.kind, 'name', s.name, 'descr', s.descr,
      'price_coins', s.price_coins, 'sort', s.sort, 'active', s.active,
      'owners', (select count(*) from public.inventory i where i.item_id = s.id)) order by s.sort, s.id), '[]')
    from public.shop_items s);
end;
$$;

create or replace function public.gm_matches(p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.gm_require(auth.uid());
  return jsonb_build_object(
    'games', (select coalesce(jsonb_agg(g order by g.opened_at desc), '[]') from (
      select g.id, g.opened_at, g.status, g.setup -> 'spar' as spar,
        (select username from public.profiles where id = g.host) host, (select username from public.profiles where id = g.guest) guest,
        (select max(winner_slot) from duanlian_private.reports r where r.game_id = g.id) winner_slot
      from duanlian_private.games g order by g.opened_at desc offset greatest(coalesce(p_offset, 0), 0) limit 50) g),
    'rooms', (select coalesce(jsonb_agg(r order by r.host_until desc), '[]') from (
      select r.id, r.code, r.spar, r.matched, r.host_until,
        (select username from public.profiles where id = r.host) host, (select username from public.profiles where id = r.guest) guest
      from duanlian_private.rooms r where r.host_until > now() order by r.host_until desc limit 50) r));
end;
$$;

create or replace function public.gm_log(p_target uuid default null, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.gm_require(auth.uid());
  return (select coalesce(jsonb_agg(l order by l.id desc), '[]') from (
    select id, at, actor_name, action, target, target_name, reason, detail from duanlian_private.gm_log
    where p_target is null or target = p_target order by id desc offset greatest(coalesce(p_offset, 0), 0) limit 100) l);
end;
$$;

-- ---------- 玩家操作 ----------
create or replace function public.gm_player_edit(p_target uuid, p_nickname text, p_avatar text, p_title text, p_rating integer, p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare v_old jsonb; v_reason text := duanlian_private.gm_reason(p_reason);
begin
  perform duanlian_private.gm_require(auth.uid()); perform duanlian_private.gm_target(p_target);
  if p_rating is not null and p_rating not between 0 and 5000 then raise exception 'bad_rating' using errcode = '22023'; end if;
  select jsonb_build_object('nickname', nickname, 'avatar', avatar, 'title', title, 'rating', rating) into v_old
    from public.profiles where id = p_target for update;
  update public.profiles set nickname = coalesce(nullif(btrim(p_nickname), ''), nickname), avatar = coalesce(p_avatar, avatar),
    title = case when p_title = '' then null else coalesce(p_title, title) end, rating = coalesce(p_rating, rating)
  where id = p_target;
  perform duanlian_private.gm_write('edit_profile', p_target, v_reason, jsonb_build_object('before', v_old,
    'after', (select jsonb_build_object('nickname', nickname, 'avatar', avatar, 'title', title, 'rating', rating) from public.profiles where id = p_target)));
end;
$$;

-- 给予 / 回收物品。p_targets：玩家 UUID 列表（批量发放）
create or replace function public.gm_item(p_targets uuid[], p_item text, p_op text, p_reason text)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare v_reason text := duanlian_private.gm_reason(p_reason); t uuid; n integer := 0; skipped integer := 0;
begin
  perform duanlian_private.gm_require(auth.uid());
  if p_op not in ('grant', 'revoke') then raise exception 'bad_op' using errcode = '22023'; end if;
  if not exists (select 1 from public.shop_items where id = p_item) then raise exception 'item_not_found'; end if;
  if coalesce(array_length(p_targets, 1), 0) not between 1 and 500 then raise exception 'bad_targets' using errcode = '22023'; end if;
  foreach t in array p_targets loop
    if not exists (select 1 from public.profiles where id = t) then skipped := skipped + 1; continue; end if;
    if p_op = 'grant' then
      insert into public.inventory (uid, item_id) values (t, p_item) on conflict do nothing;
    else
      delete from public.inventory where uid = t and item_id = p_item;
      if found then update public.profiles set title = null where id = t and title = p_item; end if;
    end if;
    if found then n := n + 1; perform duanlian_private.gm_write(p_op || '_item', t, v_reason, jsonb_build_object('item', p_item));
    else skipped := skipped + 1; end if;
  end loop;
  return jsonb_build_object('changed', n, 'skipped', skipped);
end;
$$;

-- 成就：给予 / 回收（achievements 是 {ACH_xxx: true}）
create or replace function public.gm_achievement(p_target uuid, p_ach text, p_op text, p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare v_reason text := duanlian_private.gm_reason(p_reason);
begin
  perform duanlian_private.gm_require(auth.uid()); perform duanlian_private.gm_target(p_target);
  if p_ach !~ '^ACH_(FIRST|WIN1|WIN10|WIN50|G100|HIT10|HIT25|LV3|LV4|FIN10|BRK10|PARRY20|BURN|AIR|SIDE|THROW|PERFECT|ALL|CPU2|ON1|ON10)$' then
    raise exception 'bad_achievement' using errcode = '22023'; end if;
  if p_op = 'grant' then
    update public.profiles set achievements = coalesce(achievements, '{}') || jsonb_build_object(p_ach, true) where id = p_target;
  elsif p_op = 'revoke' then
    update public.profiles set achievements = coalesce(achievements, '{}') - p_ach,
      title = case when title = p_ach then null else title end where id = p_target;
  else raise exception 'bad_op' using errcode = '22023'; end if;
  perform duanlian_private.gm_write(p_op || '_achievement', p_target, v_reason, jsonb_build_object('achievement', p_ach));
end;
$$;

-- 清空战绩：删对局记录、统计归零、段位回 1000（不动成就和物品）
create or replace function public.gm_reset_record(p_target uuid, p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare v_reason text := duanlian_private.gm_reason(p_reason); v_n integer;
begin
  perform duanlian_private.gm_require(auth.uid()); perform duanlian_private.gm_target(p_target);
  delete from public.matches where user_id = p_target; get diagnostics v_n = row_count;
  update public.profiles set stats = '{}', rating = 1000 where id = p_target;
  perform duanlian_private.gm_write('reset_record', p_target, v_reason, jsonb_build_object('matches_deleted', v_n));
end;
$$;

-- 封号：p_hours > 0 封这么多小时，-1 永久，0 解封。封号同时踢下线
create or replace function public.gm_ban(p_target uuid, p_hours integer, p_reason text)
returns timestamptz language plpgsql security definer set search_path = pg_catalog as $$
declare v_reason text := duanlian_private.gm_reason(p_reason); v_until timestamptz;
begin
  perform duanlian_private.gm_require(auth.uid()); perform duanlian_private.gm_target(p_target);
  if p_target = auth.uid() then raise exception 'cannot_ban_self' using errcode = '42501'; end if;
  if p_hours is null or (p_hours < -1) or p_hours > 87600 then raise exception 'bad_hours' using errcode = '22023'; end if;
  v_until := case when p_hours = 0 then null when p_hours = -1 then 'infinity'::timestamptz else now() + make_interval(hours => p_hours) end;
  update auth.users set banned_until = v_until where id = p_target;
  if v_until is not null then
    delete from auth.sessions where user_id = p_target;
    delete from duanlian_private.mm_queue where uid = p_target;
  end if;
  perform duanlian_private.gm_write(case when v_until is null then 'unban' else 'ban' end, p_target, v_reason,
    jsonb_build_object('hours', p_hours, 'until', v_until));
  return v_until;
end;
$$;

-- 踢下线：作废这个号所有登录会话（已发出的访问令牌最多再用约 1 小时）
create or replace function public.gm_kick(p_target uuid, p_reason text)
returns integer language plpgsql security definer set search_path = pg_catalog as $$
declare v_reason text := duanlian_private.gm_reason(p_reason); v_n integer;
begin
  perform duanlian_private.gm_require(auth.uid()); perform duanlian_private.gm_target(p_target);
  delete from auth.sessions where user_id = p_target; get diagnostics v_n = row_count;
  delete from duanlian_private.mm_queue where uid = p_target;
  perform duanlian_private.gm_write('kick', p_target, v_reason, jsonb_build_object('sessions', v_n));
  return v_n;
end;
$$;

-- ---------- 商品 ----------
create or replace function public.gm_item_save(p_id text, p_kind text, p_name text, p_descr text, p_price_coins integer, p_sort integer, p_active boolean, p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare v_reason text := duanlian_private.gm_reason(p_reason); v_old jsonb;
begin
  perform duanlian_private.gm_require(auth.uid());
  select to_jsonb(s) into v_old from public.shop_items s where id = p_id;
  insert into public.shop_items (id, kind, name, descr, price_cny, price_coins, sort, active)
  values (p_id, coalesce(p_kind, 'title'), btrim(p_name), coalesce(btrim(p_descr), ''), 1, p_price_coins, coalesce(p_sort, 100), coalesce(p_active, true))
  on conflict (id) do update set kind = excluded.kind, name = excluded.name, descr = excluded.descr,
    price_coins = excluded.price_coins, sort = excluded.sort, active = excluded.active;
  perform duanlian_private.gm_write(case when v_old is null then 'create_item' else 'edit_item' end, null, v_reason,
    jsonb_build_object('item', p_id, 'before', v_old));
end;
$$;

-- ---------- 公告 ----------
create or replace function public.gm_announcements()
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.gm_require(auth.uid());
  return (select coalesce(jsonb_agg(a order by a.id desc), '[]') from (select * from public.announcements order by id desc limit 50) a);
end;
$$;
create or replace function public.gm_announce(p_id bigint, p_body text, p_level text, p_hours integer, p_active boolean)
returns bigint language plpgsql security definer set search_path = pg_catalog as $$
declare v_id bigint;
begin
  perform duanlian_private.gm_require(auth.uid());
  if p_id is null then
    insert into public.announcements (body, level, ends_at, created_by)
    values (btrim(p_body), coalesce(p_level, 'info'), case when coalesce(p_hours, 0) > 0 then now() + make_interval(hours => p_hours) end, auth.uid())
    returning id into v_id;
  else
    update public.announcements set active = coalesce(p_active, active) where id = p_id returning id into v_id;
    if v_id is null then raise exception 'not_found'; end if;
  end if;
  perform duanlian_private.gm_write(case when p_id is null then 'announce' else 'announce_toggle' end, null, left(btrim(coalesce(p_body, '')), 200),
    jsonb_build_object('id', v_id, 'active', p_active));
  return v_id;
end;
$$;

-- ---------- 管理员（只有站长 owner 能改） ----------
create or replace function public.gm_admins()
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.gm_require(auth.uid());
  return (select coalesce(jsonb_agg(jsonb_build_object('uid', g.uid, 'username', p.username, 'nickname', p.nickname, 'role', g.role, 'added_at', g.added_at)
    order by g.role desc, g.added_at), '[]') from duanlian_private.gm_admins g left join public.profiles p on p.id = g.uid);
end;
$$;
create or replace function public.gm_admin_set(p_username text, p_role text, p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare v_reason text := duanlian_private.gm_reason(p_reason); v_uid uuid;
begin
  perform duanlian_private.gm_require(auth.uid(), true);
  select id into v_uid from public.profiles where username = lower(btrim(p_username));
  if v_uid is null then raise exception 'player_not_found'; end if;
  if v_uid = auth.uid() then raise exception 'cannot_change_self' using errcode = '42501'; end if;
  if p_role is null or p_role = '' then delete from duanlian_private.gm_admins where uid = v_uid;
  elsif p_role in ('owner', 'admin') then
    insert into duanlian_private.gm_admins (uid, role, added_by) values (v_uid, p_role, auth.uid())
    on conflict (uid) do update set role = excluded.role;
  else raise exception 'bad_role' using errcode = '22023'; end if;
  perform duanlian_private.gm_write('admin_set', v_uid, v_reason, jsonb_build_object('role', nullif(p_role, '')));
end;
$$;

-- ---------- 权限 ----------
revoke all on function duanlian_private.gm_require(uuid, boolean), duanlian_private.gm_reason(text),
  duanlian_private.gm_write(text, uuid, text, jsonb), duanlian_private.gm_target(uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['gm_me()', 'gm_overview()', 'gm_players(text, text, integer)', 'gm_player(uuid)', 'gm_catalog()',
    'gm_matches(integer)', 'gm_log(uuid, integer)', 'gm_player_edit(uuid, text, text, text, integer, text)',
    'gm_item(uuid[], text, text, text)', 'gm_achievement(uuid, text, text, text)', 'gm_reset_record(uuid, text)',
    'gm_ban(uuid, integer, text)', 'gm_kick(uuid, text)', 'gm_item_save(text, text, text, text, integer, integer, boolean, text)',
    'gm_announcements()', 'gm_announce(bigint, text, text, integer, boolean)', 'gm_admins()', 'gm_admin_set(text, text, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';

commit;
