-- 《断链》后端 v2（含好友 · 好友切磋）· 完整建库及 v1 / v1.1 升级脚本
-- 用法：Supabase 项目 → SQL Editor → New query → 整段粘贴 → Run。可以重复运行。

begin;

-- 支持全新项目，也保留 v1 资料和历史。
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text unique not null,
  nickname text not null default '无名',
  avatar text not null default 'CH_JIN',
  title text,
  stats jsonb not null default '{}'::jsonb,
  achievements jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_format check (username ~ '^[a-z0-9_]{3,16}$'),
  constraint profiles_nickname_len check (char_length(nickname) between 1 and 12)
);
alter table public.profiles enable row level security;

drop policy if exists "profiles_select_all" on public.profiles;
create policy "profiles_select_all" on public.profiles for select using (true);
drop policy if exists "profiles_insert_own" on public.profiles;
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- 2. 注册时自动建资料（账号名、昵称、头像来自注册时填写的内容）
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
begin
  insert into public.profiles (id, username, nickname, avatar)
  values (
    new.id,
    lower(coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1))),
    left(coalesce(nullif(new.raw_user_meta_data ->> 'nickname', ''), new.raw_user_meta_data ->> 'username', '无名'), 12),
    case when new.raw_user_meta_data ->> 'avatar' ~ '^CH_(JIN|LAN|YUE|YING|LING|SHUANG|LEI)$' then new.raw_user_meta_data ->> 'avatar' else 'CH_JIN' end
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- 3. 对战记录（客户端仅可读取自己的记录）
create table if not exists public.matches (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  mode text not null,
  my_char text,
  opp_char text,
  opp_id uuid,
  opp_name text,
  result text not null check (result in ('win', 'lose', 'draw')),
  rounds text,
  max_hits int,
  max_lv int,
  stage text,
  created_at timestamptz not null default now()
);
alter table public.matches enable row level security;
drop policy if exists "matches_select_own" on public.matches;
create policy "matches_select_own" on public.matches for select using (auth.uid() = user_id);
drop policy if exists "matches_insert_own" on public.matches;
create index if not exists matches_user_time on public.matches (user_id, created_at desc);


alter table public.matches add column if not exists verified boolean not null default false;
alter table public.matches add column if not exists game_id uuid;
create unique index if not exists matches_verified_game_user on public.matches (game_id, user_id) where verified;
create index if not exists matches_verified_user on public.matches (user_id) where verified;

-- v1 的累计值由客户端写入，首次升级时从可信数据重新起算。
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'profiles' and column_name = 'rating') then
    alter table public.profiles add column rating integer not null default 1000;
    update public.profiles set stats = '{}', achievements = '{}';
  end if;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.profiles'::regclass
                 and conname = 'profiles_cosmetics_format') then
    alter table public.profiles add constraint profiles_cosmetics_format check (
      avatar ~ '^CH_(JIN|LAN|YUE|YING|LING|SHUANG|LEI)$' and
      (title is null or title ~ '^ACH_(FIRST|WIN1|WIN10|WIN50|G100|HIT10|HIT25|LV3|LV4|FIN10|BRK10|PARRY20|BURN|AIR|SIDE|THROW|PERFECT|ALL|CPU2|ON1|ON10)$')
    ) not valid;
    update public.profiles set avatar = case when avatar ~ '^CH_(JIN|LAN|YUE|YING|LING|SHUANG|LEI)$' then avatar else 'CH_JIN' end,
      title = case when title ~ '^ACH_(FIRST|WIN1|WIN10|WIN50|G100|HIT10|HIT25|LV3|LV4|FIN10|BRK10|PARRY20|BURN|AIR|SIDE|THROW|PERFECT|ALL|CPU2|ON1|ON10)$' then title end
    where avatar !~ '^CH_(JIN|LAN|YUE|YING|LING|SHUANG|LEI)$'
       or title !~ '^ACH_(FIRST|WIN1|WIN10|WIN50|G100|HIT10|HIT25|LV3|LV4|FIN10|BRK10|PARRY20|BURN|AIR|SIDE|THROW|PERFECT|ALL|CPU2|ON1|ON10)$';
    alter table public.profiles validate constraint profiles_cosmetics_format;
  end if;
end;
$$;

create or replace function public.touch_duanlian_profile()
returns trigger language plpgsql set search_path = pg_catalog as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists touch_duanlian_profile on public.profiles;
create trigger touch_duanlian_profile before update on public.profiles
  for each row execute function public.touch_duanlian_profile();

revoke all on public.profiles, public.matches from public, anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant update (nickname, avatar, title) on public.profiles to authenticated;
grant select on public.matches to authenticated;
revoke all on function public.handle_new_user(), public.touch_duanlian_profile() from public, anon, authenticated;

create schema if not exists duanlian_private;
revoke all on schema duanlian_private from public, anon, authenticated;

create table if not exists duanlian_private.rpc_limits (
  uid uuid references auth.users on delete cascade,
  route text,
  bucket timestamptz not null,
  calls integer not null,
  primary key (uid, route)
);
create table if not exists duanlian_private.games (
  id uuid primary key,
  room_code text not null,
  host uuid not null references public.profiles on delete cascade,
  guest uuid not null references public.profiles on delete cascade,
  setup jsonb not null,
  opened_at timestamptz not null default now(),
  first_report_at timestamptz,
  status text not null default 'pending' check (status in ('pending', 'disputed', 'verified', 'expired')),
  check (host <> guest)
);
create table if not exists duanlian_private.reports (
  game_id uuid references duanlian_private.games on delete cascade,
  uid uuid references public.profiles on delete cascade,
  frames integer not null,
  final_hash bigint not null,
  winner_slot integer not null,
  summary jsonb not null,
  primary key (game_id, uid)
);
create table if not exists duanlian_private.mm_queue (
  uid uuid primary key references public.profiles on delete cascade,
  rating integer not null,
  enqueued_at timestamptz not null default now(),
  seen_at timestamptz not null default now(),
  assignment jsonb,
  assigned_at timestamptz
);
create index if not exists mm_queue_rating on duanlian_private.mm_queue (rating, enqueued_at)
  where assignment is null;
alter table duanlian_private.rpc_limits enable row level security;
alter table duanlian_private.games enable row level security;
alter table duanlian_private.reports enable row level security;
alter table duanlian_private.mm_queue enable row level security;

create or replace function duanlian_private.check_limit(p_uid uuid, p_route text, p_max integer)
returns void language plpgsql set search_path = pg_catalog as $$
declare
  v_bucket timestamptz := date_trunc('minute', clock_timestamp());
begin
  if p_uid is null then raise exception 'authentication required' using errcode = '42501'; end if;
  insert into duanlian_private.rpc_limits as l (uid, route, bucket, calls)
    values (p_uid, p_route, v_bucket, 1)
    on conflict (uid, route) do update set bucket = excluded.bucket,
      calls = case when l.bucket = excluded.bucket then l.calls + 1 else 1 end
    where l.bucket <> excluded.bucket or l.calls < p_max;
  if not found then raise exception 'rate limit exceeded'; end if;
end;
$$;

create or replace function public.online_open(p_game uuid, p_code text, p_guest uuid, p_setup jsonb)
returns uuid language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'online_open', 12);
  if p_game is null or p_guest is null or p_guest = me or p_code is null or p_code !~ '^[0-9]{4}$'
    or jsonb_typeof(p_setup) is distinct from 'object' or octet_length(p_setup::text) > 8192
    or not coalesce((p_setup #>> '{sel,p1}') ~ '^CH_(JIN|LAN|YUE|YING|LING|SHUANG|LEI)$'
      and (p_setup #>> '{sel,p2}') ~ '^CH_(JIN|LAN|YUE|YING|LING|SHUANG|LEI)$'
      and (p_setup #>> '{sel,stage}') ~ '^STG_0[1-6]$', false)
  then raise exception 'invalid game setup' using errcode = '22023'; end if;
  insert into duanlian_private.games (id, room_code, host, guest, setup)
    values (p_game, p_code, me, p_guest, p_setup) on conflict (id) do nothing;
  if not exists (select 1 from duanlian_private.games where id = p_game and host = me
                 and guest = p_guest and room_code = p_code and setup = p_setup) then
    raise exception 'game unavailable' using errcode = '42501';
  end if;
  return p_game;
end;
$$;

create or replace function public.online_game(p_game uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
  g duanlian_private.games;
begin
  perform duanlian_private.check_limit(me, 'online_game', 60);
  select * into g from duanlian_private.games
    where id = p_game and me in (host, guest) and opened_at > now() - interval '2 hours';
  if not found then return null; end if;
  return jsonb_build_object('code', g.room_code, 'host', g.host, 'guest', g.guest, 'setup', g.setup);
end;
$$;

-- Realtime 私有频道使用 JWT 中的用户 ID 校验参赛资格。
create or replace function public.can_join_duanlian_game(p_topic text)
returns boolean language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  if p_topic is null or p_topic !~ '^duanlian-game:[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then
    return false;
  end if;
  return exists (select 1 from duanlian_private.games
    where id = substr(p_topic, 15)::uuid and auth.uid() in (host, guest)
      and opened_at > now() - interval '2 hours');
end;
$$;

-- 限制规则阻止其它宽松策略意外开放游戏主题，普通房间及其它主题继续沿用原有策略。
drop policy if exists duanlian_game_guard on realtime.messages;
create policy duanlian_game_guard on realtime.messages as restrictive for all to public
  using (case when (select realtime.topic()) like 'duanlian-game:%'
         then extension = 'broadcast' and (select public.can_join_duanlian_game(realtime.topic())) else true end)
  with check (case when (select realtime.topic()) like 'duanlian-game:%'
         then extension = 'broadcast' and (select public.can_join_duanlian_game(realtime.topic())) else true end);
drop policy if exists duanlian_game_read on realtime.messages;
create policy duanlian_game_read on realtime.messages for select to authenticated
  using (extension = 'broadcast' and (select public.can_join_duanlian_game(realtime.topic())));
drop policy if exists duanlian_game_write on realtime.messages;
create policy duanlian_game_write on realtime.messages for insert to authenticated
  with check (extension = 'broadcast' and (select public.can_join_duanlian_game(realtime.topic())));

create or replace function duanlian_private.refresh_stats(p_uid uuid)
returns void language plpgsql set search_path = pg_catalog as $$
declare
  s jsonb;
  a jsonb;
begin
  with selected as (
    select * from public.matches where user_id = p_uid and verified
  ), chars as (
    select my_char, count(*) as g, count(*) filter (where result = 'win') as w from selected group by my_char
  ), totals as (
    select count(*) as games, count(*) filter (where result = 'win') as wins,
      count(*) filter (where result = 'lose') as losses, count(*) filter (where result = 'draw') as draws,
      coalesce(max(max_hits), 0) as hits, coalesce(max(max_lv), 0) as lv from selected
  )
  select jsonb_build_object('games', games, 'wins', wins, 'losses', losses, 'draws', draws,
    'onG', games, 'onW', wins, 'maxHits', hits, 'maxLv', lv, 'chars',
    coalesce((select jsonb_object_agg(my_char, jsonb_build_object('g', g, 'w', w)) from chars), '{}')),
    coalesce((select jsonb_object_agg(id, true) from (values
      ('ACH_FIRST', games >= 1), ('ACH_WIN1', wins >= 1), ('ACH_WIN10', wins >= 10),
      ('ACH_WIN50', wins >= 50), ('ACH_G100', games >= 100), ('ACH_HIT10', hits >= 10),
      ('ACH_HIT25', hits >= 25), ('ACH_LV3', lv >= 3), ('ACH_LV4', lv >= 4),
      ('ACH_ON1', wins >= 1), ('ACH_ON10', wins >= 10),
      ('ACH_ALL', (select count(*) from chars where w > 0) = 7)
    ) as unlocked(id, earned) where earned), '{}')
  into s, a from totals;
  update public.profiles set stats = s, achievements = achievements || a where id = p_uid;
end;
$$;

create or replace function duanlian_private.result_info(p_uid uuid, p_status text)
returns jsonb language sql set search_path = pg_catalog as $$
  select jsonb_build_object('status', p_status, 'stats', stats, 'achievements', achievements, 'rating', rating)
  from public.profiles where id = p_uid;
$$;

create or replace function public.submit_online_result(p_game uuid, p_frames integer, p_final_hash bigint, p_winner_slot integer, p_summary jsonb)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
  g duanlian_private.games;
  r duanlian_private.reports;
  n integer;
  player jsonb;
  h_rating integer;
  g_rating integer;
  delta integer;
begin
  perform duanlian_private.check_limit(me, 'online_result', 45);
  select * into g from duanlian_private.games where id = p_game and me in (host, guest) for update;
  if not found then raise exception 'game unavailable' using errcode = '42501'; end if;
  -- 好友切磋不计战绩、不改段位分。
  if coalesce(g.setup ->> 'spar', 'false') = 'true' then return duanlian_private.result_info(me, 'unrated'); end if;

  if g.status <> 'pending' then return duanlian_private.result_info(me, g.status); end if;
  if g.opened_at <= now() - interval '2 hours' or g.first_report_at <= now() - interval '10 minutes' then
    update duanlian_private.games set status = 'expired' where id = p_game;
    return duanlian_private.result_info(me, 'expired');
  end if;

  if p_frames is null or p_frames not between 1 and 432000 or p_final_hash is null or p_final_hash not between 0 and 4294967295
    or p_winner_slot is null or p_winner_slot not between -1 and 1 or jsonb_typeof(p_summary) is distinct from 'array'
    or octet_length(p_summary::text) > 2048
  then raise exception 'invalid result' using errcode = '22023'; end if;
  if jsonb_array_length(p_summary) <> 2 then raise exception 'invalid summary' using errcode = '22023'; end if;
  for n in 0..1 loop
    player := p_summary -> n;
    if not coalesce(jsonb_typeof(player) = 'object'
      and jsonb_typeof(player -> 'rounds') = 'number' and (player ->> 'rounds') ~ '^[0-9]$'
      and jsonb_typeof(player -> 'hits') = 'number' and (player ->> 'hits') ~ '^[0-9]{1,6}$'
      and jsonb_typeof(player -> 'level') = 'number' and (player ->> 'level') ~ '^[0-4]$', false)
    then raise exception 'invalid player summary' using errcode = '22023'; end if;
  end loop;
  if sign((p_summary #>> '{0,rounds}')::int - (p_summary #>> '{1,rounds}')::int)
     <> (case p_winner_slot when 0 then 1 when 1 then -1 else 0 end)
  then raise exception 'winner does not match rounds' using errcode = '22023'; end if;

  -- 每个参赛者的第一份报告固定。对同一局的并发请求由游戏行锁串行处理。
  insert into duanlian_private.reports (game_id, uid, frames, final_hash, winner_slot, summary)
    values (p_game, me, p_frames, p_final_hash, p_winner_slot, p_summary) on conflict do nothing;
  if not found then return duanlian_private.result_info(me, 'pending'); end if;
  update duanlian_private.games set first_report_at = coalesce(first_report_at, now()) where id = p_game;
  select * into r from duanlian_private.reports where game_id = p_game and uid <> me;
  if not found then return duanlian_private.result_info(me, 'pending'); end if;

  if (r.frames, r.final_hash, r.winner_slot, r.summary) is distinct from (p_frames, p_final_hash, p_winner_slot, p_summary) then
    update duanlian_private.games set status = 'disputed' where id = p_game;
    return duanlian_private.result_info(me, 'disputed');
  end if;

  -- 两局共享一名玩家时，按 UUID 顺序锁资料，Elo 和累计值基于已提交的最新状态。
  perform id from public.profiles where id in (g.host, g.guest) order by id for update;
  select rating into h_rating from public.profiles where id = g.host;
  select rating into g_rating from public.profiles where id = g.guest;
  delta := round(32 * ((case p_winner_slot when 0 then 1.0 when 1 then 0.0 else 0.5 end)
    - 1.0 / (1.0 + power(10.0, (g_rating - h_rating) / 400.0))));

  insert into public.matches (user_id, mode, my_char, opp_char, opp_id, opp_name, result, rounds, max_hits, max_lv, stage, verified, game_id)
  select x.uid, 'online', g.setup #>> array['sel', x.mine], g.setup #>> array['sel', x.theirs], x.opponent, p.nickname,
    case when p_winner_slot = -1 then 'draw' when p_winner_slot = x.slot then 'win' else 'lose' end,
    concat(p_summary -> x.slot ->> 'rounds', ':', p_summary -> (1 - x.slot) ->> 'rounds'),
    (p_summary -> x.slot ->> 'hits')::int, (p_summary -> x.slot ->> 'level')::int, g.setup #>> '{sel,stage}', true, p_game
  from (values (g.host, g.guest, 0, 'p1', 'p2'), (g.guest, g.host, 1, 'p2', 'p1')) as x(uid, opponent, slot, mine, theirs)
  join public.profiles p on p.id = x.opponent;

  update public.profiles set rating = case when id = g.host then h_rating + delta else g_rating - delta end
    where id in (g.host, g.guest);
  perform duanlian_private.refresh_stats(g.host);
  perform duanlian_private.refresh_stats(g.guest);
  update duanlian_private.games set status = 'verified' where id = p_game;
  return duanlian_private.result_info(me, 'verified');
end;
$$;

create or replace function public.record_cpu_match(p_my_char text, p_opp_char text, p_result text,
  p_rounds text, p_hits integer, p_level integer, p_stage text, p_ai text)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'cpu_result', 20);
  if not coalesce(p_my_char ~ '^CH_(JIN|LAN|YUE|YING|LING|SHUANG|LEI)$'
    and p_opp_char ~ '^CH_(JIN|LAN|YUE|YING|LING|SHUANG|LEI)$'
    and p_stage ~ '^STG_0[1-6]$' and p_rounds ~ '^[0-9]:[0-9]$'
    and p_hits between 0 and 999999 and p_level between 0 and 4
    and char_length(p_ai) <= 24 and p_result in ('win', 'lose', 'draw'), false)
  then raise exception 'invalid CPU record' using errcode = '22023'; end if;
  insert into public.matches (user_id, mode, my_char, opp_char, opp_name, result, rounds, max_hits, max_lv, stage)
    values (me, 'cpu', p_my_char, p_opp_char, '电脑 · ' || p_ai, p_result, p_rounds, p_hits, p_level, p_stage);
end;
$$;

create or replace function public.mm_join()
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'mm_join', 15);
  perform pg_advisory_xact_lock(479887002);
  insert into duanlian_private.mm_queue as q (uid, rating) select me, rating from public.profiles where id = me
    on conflict (uid) do update set seen_at = now(), rating = excluded.rating,
      enqueued_at = case when q.seen_at > now() - interval '8 seconds' and q.assignment is null then q.enqueued_at else now() end,
      assignment = null, assigned_at = null;
end;
$$;

create or replace function public.mm_leave()
returns void language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.check_limit(auth.uid(), 'mm_leave', 15);
  perform pg_advisory_xact_lock(479887002);
  delete from duanlian_private.mm_queue where uid = auth.uid();
end;
$$;

create or replace function public.mm_poll()
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
  mine duanlian_private.mm_queue;
  other duanlian_private.mm_queue;
  pair uuid := gen_random_uuid();
  code text := (1000 + floor(random() * 9000)::integer)::text;
  am_host boolean;
  assigned jsonb;
begin
  perform duanlian_private.check_limit(me, 'mm_poll', 55);
  perform pg_advisory_xact_lock(479887002);
  delete from duanlian_private.mm_queue where
    (assignment is null and seen_at <= now() - interval '8 seconds') or assigned_at <= now() - interval '15 seconds';
  update duanlian_private.mm_queue set seen_at = now() where uid = me returning * into mine;
  if not found then return jsonb_build_object('status', 'idle'); end if;
  if mine.assignment is not null then return mine.assignment; end if;
  select * into other from duanlian_private.mm_queue q
    where q.uid <> me and q.assignment is null and abs(q.rating - mine.rating) <=
      100 + 100 * floor(greatest(extract(epoch from now() - q.enqueued_at), extract(epoch from now() - mine.enqueued_at)) / 10)
    order by abs(q.rating - mine.rating), q.enqueued_at, q.uid limit 1;
  if not found then return jsonb_build_object('status', 'searching'); end if;

  am_host := (mine.enqueued_at, mine.uid) < (other.enqueued_at, other.uid);
  assigned := jsonb_build_object('status', 'matched', 'pair', pair, 'code', code, 'host', am_host, 'peer', other.uid);
  update duanlian_private.mm_queue set assignment = assigned, assigned_at = now() where uid = me;
  update duanlian_private.mm_queue set assignment = assigned || jsonb_build_object('host', not am_host, 'peer', me),
    assigned_at = now() where uid = other.uid;
  return assigned;
end;
$$;

-- 好友：本人发请求，对方同意，双方都能删除。客户端只能写这几个列。
create table if not exists public.friendships (
  id bigint generated always as identity primary key,
  requester uuid not null default auth.uid() references auth.users (id) on delete cascade,
  addressee uuid not null references auth.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  constraint friendships_not_self check (requester <> addressee)
);
create unique index if not exists friendships_pair on public.friendships (least(requester, addressee), greatest(requester, addressee));
create index if not exists friendships_addressee on public.friendships (addressee);
alter table public.friendships enable row level security;
drop policy if exists "friendships_select_own" on public.friendships;
create policy "friendships_select_own" on public.friendships for select using (auth.uid() in (requester, addressee));
drop policy if exists "friendships_insert_request" on public.friendships;
create policy "friendships_insert_request" on public.friendships for insert with check (auth.uid() = requester and status = 'pending');
drop policy if exists "friendships_accept" on public.friendships;
create policy "friendships_accept" on public.friendships for update using (auth.uid() = addressee) with check (auth.uid() = addressee and status = 'accepted');
drop policy if exists "friendships_delete_own" on public.friendships;
create policy "friendships_delete_own" on public.friendships for delete using (auth.uid() in (requester, addressee));
create or replace function duanlian_private.friend_request_limit()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.check_limit(auth.uid(), 'friend_request', 20);
  return new;
end;
$$;
drop trigger if exists friendships_limit on public.friendships;
create trigger friendships_limit before insert on public.friendships
  for each row execute function duanlian_private.friend_request_limit();
revoke all on public.friendships from public, anon, authenticated;
grant select, delete on public.friendships to authenticated;
grant insert (requester, addressee) on public.friendships to authenticated;
grant update (status) on public.friendships to authenticated;
revoke all on function duanlian_private.friend_request_limit() from public, anon, authenticated;

create or replace view public.duanlian_leaderboard as
select row_number() over (order by rating desc, (stats ->> 'onW')::bigint desc, id) as rank,
  nickname, avatar, rating, (stats ->> 'onG')::bigint as games, (stats ->> 'onW')::bigint as wins,
  round(100.0 * (stats ->> 'onW')::bigint / nullif((stats ->> 'onG')::bigint, 0), 1) as win_rate
from public.profiles
where (stats ->> 'onG')::bigint > 0
order by rank limit 100;
revoke all on public.duanlian_leaderboard from public, anon, authenticated;
grant select on public.duanlian_leaderboard to anon, authenticated;

revoke all on function public.online_open(uuid, text, uuid, jsonb), public.online_game(uuid),
  public.can_join_duanlian_game(text), public.submit_online_result(uuid, integer, bigint, integer, jsonb),
  public.record_cpu_match(text, text, text, text, integer, integer, text, text),
  public.mm_join(), public.mm_leave(), public.mm_poll() from public, anon, authenticated;
grant execute on function public.online_open(uuid, text, uuid, jsonb), public.online_game(uuid),
  public.can_join_duanlian_game(text), public.submit_online_result(uuid, integer, bigint, integer, jsonb),
  public.record_cpu_match(text, text, text, text, integer, integer, text, text),
  public.mm_join(), public.mm_leave(), public.mm_poll() to authenticated;
-- 匿名私有订阅也需要评估限制策略。此函数只按 auth.uid() 返回布尔值。
grant execute on function public.can_join_duanlian_game(text) to anon;

notify pgrst, 'reload schema';
commit;

-- 《断链》v1.4：服务器分配房号、控制房间席位并保存邀请。
begin;

alter table duanlian_private.mm_queue add column if not exists protocol integer not null default 13;

create table if not exists duanlian_private.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[0-9]{4}$'),
  host uuid not null unique references public.profiles on delete cascade,
  guest uuid references public.profiles on delete set null,
  invited uuid references public.profiles on delete set null,
  invite_until timestamptz,
  spar boolean not null default false,
  matched boolean not null default false,
  host_until timestamptz not null default now() + interval '90 seconds',
  guest_until timestamptz,
  check (host <> guest),
  check (host <> invited)
);
create index if not exists rooms_host_until on duanlian_private.rooms (host_until);
create index if not exists rooms_invited on duanlian_private.rooms (invited) where invited is not null;
alter table duanlian_private.rooms enable row level security;

create or replace function duanlian_private.are_friends(a uuid, b uuid)
returns boolean language sql stable set search_path = pg_catalog as $$
  select exists (select 1 from public.friendships where least(requester, addressee) = least(a, b)
    and greatest(requester, addressee) = greatest(a, b) and status = 'accepted' and a is not null and b is not null);
$$;

create or replace function duanlian_private.room_info(r duanlian_private.rooms)
returns jsonb language sql stable set search_path = pg_catalog as $$
  select jsonb_build_object('id', r.id, 'code', r.code, 'host', r.host, 'guest',
    case when r.guest_until > now() then r.guest end, 'spar', r.spar, 'matched', r.matched);
$$;

create or replace function duanlian_private.make_room(p_id uuid, p_host uuid, p_guest uuid, p_spar boolean)
returns duanlian_private.rooms language plpgsql set search_path = pg_catalog as $$
declare
  r duanlian_private.rooms;
  candidate text;
begin
  perform pg_advisory_xact_lock(479887003);
  delete from duanlian_private.rooms where host_until <= now() or host = p_host;
  for attempt in 1..32 loop
    candidate := (1000 + floor(random() * 9000)::integer)::text;
    insert into duanlian_private.rooms (id, code, host, guest, guest_until, spar, matched)
      values (p_id, candidate, p_host, p_guest, case when p_guest is not null then now() + interval '90 seconds' end,
        p_spar, p_guest is not null)
      on conflict (code) do nothing returning * into r;
    if found then return r; end if;
  end loop;
  raise exception 'room codes busy';
end;
$$;

create or replace function public.room_create(p_spar boolean)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'room_create', 12);
  return duanlian_private.room_info(duanlian_private.make_room(gen_random_uuid(), me, null, coalesce(p_spar, false)));
end;
$$;

create or replace function public.room_enter(p_code text, p_room uuid default null)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
  r duanlian_private.rooms;
begin
  perform duanlian_private.check_limit(me, 'room_enter', 24);
  select * into r from duanlian_private.rooms
    where code = p_code and (p_room is null or id = p_room) and host_until > now() for update;
  if not found then return jsonb_build_object('status', 'missing'); end if;
  if r.host = me then return duanlian_private.room_info(r); end if;
  if r.spar and not duanlian_private.are_friends(me, r.host) then return jsonb_build_object('status', 'friends_only'); end if;
  if r.matched and r.guest is distinct from me then return jsonb_build_object('status', 'full'); end if;
  if r.guest_until > now() and r.guest is distinct from me then return jsonb_build_object('status', 'full'); end if;
  if r.invite_until > now() and r.invited is distinct from me and r.guest is distinct from me then
    return jsonb_build_object('status', 'reserved');
  end if;
  update duanlian_private.rooms set guest = me, guest_until = now() + interval '90 seconds', invited = null, invite_until = null
    where id = r.id returning * into r;
  return duanlian_private.room_info(r);
end;
$$;

create or replace function public.room_touch(p_room uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
  r duanlian_private.rooms;
begin
  perform duanlian_private.check_limit(me, 'room_touch', 24);
  update duanlian_private.rooms set
    host_until = case when host = me then now() + interval '90 seconds' else host_until end,
    guest_until = case when guest = me then now() + interval '90 seconds' else guest_until end
  where id = p_room and host_until > now() and (host = me or (guest = me and guest_until > now()))
  returning * into r;
  if not found then return null; end if;
  return duanlian_private.room_info(r);
end;
$$;

create or replace function public.room_exit(p_room uuid)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'room_exit', 24);
  delete from duanlian_private.rooms where id = p_room and (host = me or (matched and guest = me));
  if not found then update duanlian_private.rooms set guest = null, guest_until = null where id = p_room and guest = me; end if;
end;
$$;

create or replace function public.room_invite(p_room uuid, p_guest uuid)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'room_invite', 12);
  update duanlian_private.rooms r set invited = p_guest, invite_until = now() + interval '45 seconds'
    where r.id = p_room and r.host = me and r.host_until > now() and not r.matched
      and p_guest <> me and (r.guest_until is null or r.guest_until <= now())
      and (not r.spar or duanlian_private.are_friends(me, p_guest))
      and exists (select 1 from public.profiles p where p.id = p_guest);
  return found;
end;
$$;

create or replace function public.room_invites()
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'room_invites', 30);
  return coalesce((select jsonb_agg(to_jsonb(i) order by i.expires desc)
    from (select r.id, r.code, r.spar, r.invite_until as expires, p.id as uid, p.nickname as nick, p.avatar, p.title
      from duanlian_private.rooms r join public.profiles p on p.id = r.host
      where r.invited = me and r.host_until > now() and r.invite_until > now()
        and (not r.spar or duanlian_private.are_friends(me, r.host))
      order by r.invite_until desc limit 8) i), '[]');
end;
$$;

create or replace function public.room_decline(p_room uuid)
returns void language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.check_limit(auth.uid(), 'room_decline', 24);
  update duanlian_private.rooms set invited = null, invite_until = null
    where id = p_room and invited = auth.uid();
end;
$$;

create or replace function public.room_start(p_room uuid, p_game uuid, p_setup jsonb)
returns uuid language plpgsql security definer set search_path = pg_catalog as $$
declare
  r duanlian_private.rooms;
begin
  select * into r from duanlian_private.rooms
    where id = p_room and host = auth.uid() and host_until > now() and guest_until > now() for update;
  if not found or (r.spar and not duanlian_private.are_friends(r.host, r.guest))
    or (p_setup -> 'spar') is distinct from to_jsonb(r.spar)
  then raise exception 'room unavailable' using errcode = '42501'; end if;
  return public.online_open(p_game, r.code, r.guest, p_setup);
end;
$$;

create or replace function public.can_join_duanlian_room(p_topic text)
returns boolean language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  if p_topic is null or p_topic !~ '^duanlian-room:[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then return false; end if;
  return exists (select 1 from duanlian_private.rooms
    where id = substr(p_topic, 15)::uuid and host_until > now()
      and (auth.uid() = host or (auth.uid() = guest and guest_until > now())));
end;
$$;

drop policy if exists duanlian_room_guard on realtime.messages;
create policy duanlian_room_guard on realtime.messages as restrictive for all to public
  using (case when (select realtime.topic()) like 'duanlian-room:%'
         then extension in ('broadcast', 'presence') and (select public.can_join_duanlian_room(realtime.topic())) else true end)
  with check (case when (select realtime.topic()) like 'duanlian-room:%'
         then extension in ('broadcast', 'presence') and (select public.can_join_duanlian_room(realtime.topic())) else true end);
drop policy if exists duanlian_room_read on realtime.messages;
create policy duanlian_room_read on realtime.messages for select to authenticated
  using (extension in ('broadcast', 'presence') and (select public.can_join_duanlian_room(realtime.topic())));
drop policy if exists duanlian_room_write on realtime.messages;
create policy duanlian_room_write on realtime.messages for insert to authenticated
  with check (extension in ('broadcast', 'presence') and (select public.can_join_duanlian_room(realtime.topic())));

drop function if exists public.mm_join();
create or replace function public.mm_join(p_protocol integer default 13)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'mm_join', 15);
  if p_protocol is null or p_protocol not in (13, 14) then raise exception 'unsupported protocol'; end if;
  perform pg_advisory_xact_lock(479887002);
  insert into duanlian_private.mm_queue as q (uid, rating, protocol) select me, rating, p_protocol from public.profiles where id = me
    on conflict (uid) do update set seen_at = now(), rating = excluded.rating, protocol = excluded.protocol,
      enqueued_at = case when q.protocol = p_protocol and q.seen_at > now() - interval '8 seconds' and q.assignment is null
        then q.enqueued_at else now() end, assignment = null, assigned_at = null;
end;
$$;

drop function if exists public.mm_poll();
create or replace function public.mm_poll(p_protocol integer default 13)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
  mine duanlian_private.mm_queue;
  other duanlian_private.mm_queue;
  pair uuid := gen_random_uuid();
  code text := (1000 + floor(random() * 9000)::integer)::text;
  am_host boolean;
  assigned jsonb;
  r duanlian_private.rooms;
begin
  perform duanlian_private.check_limit(me, 'mm_poll', 55);
  perform pg_advisory_xact_lock(479887002);
  delete from duanlian_private.mm_queue where
    (assignment is null and seen_at <= now() - interval '8 seconds') or assigned_at <= now() - interval '15 seconds';
  update duanlian_private.mm_queue set seen_at = now() where uid = me and protocol = p_protocol returning * into mine;
  if not found then return jsonb_build_object('status', 'idle'); end if;
  if mine.assignment is not null then return mine.assignment; end if;
  select * into other from duanlian_private.mm_queue q
    where q.uid <> me and q.protocol = p_protocol and q.assignment is null and abs(q.rating - mine.rating) <=
      100 + 100 * floor(greatest(extract(epoch from now() - q.enqueued_at), extract(epoch from now() - mine.enqueued_at)) / 10)
    order by abs(q.rating - mine.rating), q.enqueued_at, q.uid limit 1;
  if not found then return jsonb_build_object('status', 'searching'); end if;

  am_host := (mine.enqueued_at, mine.uid) < (other.enqueued_at, other.uid);
  if p_protocol = 14 then
    r := duanlian_private.make_room(pair, case when am_host then me else other.uid end,
      case when am_host then other.uid else me end, false);
    code := r.code;
  end if;
  assigned := jsonb_build_object('status', 'matched', 'pair', pair, 'code', code, 'host', am_host, 'peer', other.uid);
  update duanlian_private.mm_queue set assignment = assigned, assigned_at = now() where uid = me;
  update duanlian_private.mm_queue set assignment = assigned || jsonb_build_object('host', not am_host, 'peer', me),
    assigned_at = now() where uid = other.uid;
  return assigned;
end;
$$;

revoke all on function public.room_create(boolean), public.room_enter(text, uuid), public.room_touch(uuid),
  public.room_exit(uuid), public.room_invite(uuid, uuid), public.room_invites(), public.room_decline(uuid),
  public.room_start(uuid, uuid, jsonb), public.can_join_duanlian_room(text), public.mm_join(integer), public.mm_poll(integer)
  from public, anon, authenticated;
grant execute on function public.room_create(boolean), public.room_enter(text, uuid), public.room_touch(uuid),
  public.room_exit(uuid), public.room_invite(uuid, uuid), public.room_invites(), public.room_decline(uuid),
  public.room_start(uuid, uuid, jsonb), public.can_join_duanlian_room(text), public.mm_join(integer), public.mm_poll(integer)
  to authenticated;
grant execute on function public.can_join_duanlian_room(text) to anon;

notify pgrst, 'reload schema';
commit;

-- 《断链》v1.7：地面战斗协议 15。现有房间保留协议 14。

begin;

alter table duanlian_private.rooms add column if not exists protocol integer not null default 14
  check (protocol in (14, 15));

create or replace function duanlian_private.room_info(r duanlian_private.rooms)
returns jsonb language sql stable set search_path = pg_catalog as $$
  select jsonb_build_object('id', r.id, 'code', r.code, 'host', r.host, 'guest',
    case when r.guest_until > now() then r.guest end, 'spar', r.spar, 'matched', r.matched, 'protocol', r.protocol);
$$;

create or replace function duanlian_private.make_room(p_id uuid, p_host uuid, p_guest uuid, p_spar boolean, p_protocol integer)
returns duanlian_private.rooms language plpgsql set search_path = pg_catalog as $$
declare
  r duanlian_private.rooms;
begin
  if p_protocol is null or p_protocol not in (14, 15) then raise exception 'unsupported protocol'; end if;
  r := duanlian_private.make_room(p_id, p_host, p_guest, p_spar);
  update duanlian_private.rooms set protocol = p_protocol where id = r.id returning * into r;
  return r;
end;
$$;

create or replace function public.room_create(p_spar boolean, p_protocol integer)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'room_create', 12);
  return duanlian_private.room_info(duanlian_private.make_room(gen_random_uuid(), me, null, coalesce(p_spar, false), p_protocol));
end;
$$;

create or replace function public.room_enter(p_code text, p_room uuid, p_protocol integer)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
  r duanlian_private.rooms;
begin
  perform duanlian_private.check_limit(me, 'room_enter', 24);
  select * into r from duanlian_private.rooms
    where code = p_code and (p_room is null or id = p_room) and host_until > now() for update;
  if not found then return jsonb_build_object('status', 'missing'); end if;
  if r.protocol is distinct from p_protocol then return jsonb_build_object('status', 'version_mismatch'); end if;
  if r.host = me then return duanlian_private.room_info(r); end if;
  if r.spar and not duanlian_private.are_friends(me, r.host) then return jsonb_build_object('status', 'friends_only'); end if;
  if r.matched and r.guest is distinct from me then return jsonb_build_object('status', 'full'); end if;
  if r.guest_until > now() and r.guest is distinct from me then return jsonb_build_object('status', 'full'); end if;
  if r.invite_until > now() and r.invited is distinct from me and r.guest is distinct from me then
    return jsonb_build_object('status', 'reserved');
  end if;
  update duanlian_private.rooms set guest = me, guest_until = now() + interval '90 seconds', invited = null, invite_until = null
    where id = r.id returning * into r;
  return duanlian_private.room_info(r);
end;
$$;

create or replace function public.room_enter(p_code text, p_room uuid default null)
returns jsonb language sql security definer set search_path = pg_catalog as $$
  select public.room_enter(p_code, p_room, 14);
$$;

create or replace function public.room_invites(p_protocol integer)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'room_invites', 30);
  return coalesce((select jsonb_agg(to_jsonb(i) order by i.expires desc)
    from (select r.id, r.code, r.spar, r.invite_until as expires, p.id as uid, p.nickname as nick, p.avatar, p.title
      from duanlian_private.rooms r join public.profiles p on p.id = r.host
      where r.protocol = p_protocol and r.invited = me and r.host_until > now() and r.invite_until > now()
        and (not r.spar or duanlian_private.are_friends(me, r.host))
      order by r.invite_until desc limit 8) i), '[]');
end;
$$;

create or replace function public.room_invites()
returns jsonb language sql security definer set search_path = pg_catalog as $$
  select public.room_invites(14);
$$;

create or replace function public.room_start(p_room uuid, p_game uuid, p_setup jsonb)
returns uuid language plpgsql security definer set search_path = pg_catalog as $$
declare
  r duanlian_private.rooms;
begin
  select * into r from duanlian_private.rooms
    where id = p_room and host = auth.uid() and host_until > now() and guest_until > now() for update;
  if not found or (r.spar and not duanlian_private.are_friends(r.host, r.guest))
    or coalesce(p_setup -> 'protocol', to_jsonb(14)) is distinct from to_jsonb(r.protocol)
    or (p_setup -> 'spar') is distinct from to_jsonb(r.spar)
  then raise exception 'room unavailable' using errcode = '42501'; end if;
  return public.online_open(p_game, r.code, r.guest, p_setup);
end;
$$;

create or replace function public.mm_join(p_protocol integer default 13)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'mm_join', 15);
  if p_protocol is null or p_protocol not in (13, 14, 15) then raise exception 'unsupported protocol'; end if;
  perform pg_advisory_xact_lock(479887002);
  insert into duanlian_private.mm_queue as q (uid, rating, protocol) select me, rating, p_protocol from public.profiles where id = me
    on conflict (uid) do update set seen_at = now(), rating = excluded.rating, protocol = excluded.protocol,
      enqueued_at = case when q.protocol = p_protocol and q.seen_at > now() - interval '8 seconds' and q.assignment is null
        then q.enqueued_at else now() end, assignment = null, assigned_at = null;
end;
$$;

create or replace function public.mm_poll(p_protocol integer default 13)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
  mine duanlian_private.mm_queue;
  other duanlian_private.mm_queue;
  pair uuid := gen_random_uuid();
  code text := (1000 + floor(random() * 9000)::integer)::text;
  am_host boolean;
  assigned jsonb;
  r duanlian_private.rooms;
begin
  perform duanlian_private.check_limit(me, 'mm_poll', 55);
  perform pg_advisory_xact_lock(479887002);
  delete from duanlian_private.mm_queue where
    (assignment is null and seen_at <= now() - interval '8 seconds') or assigned_at <= now() - interval '15 seconds';
  update duanlian_private.mm_queue set seen_at = now() where uid = me and protocol = p_protocol returning * into mine;
  if not found then return jsonb_build_object('status', 'idle'); end if;
  if mine.assignment is not null then return mine.assignment; end if;
  select * into other from duanlian_private.mm_queue q
    where q.uid <> me and q.protocol = p_protocol and q.assignment is null and abs(q.rating - mine.rating) <=
      100 + 100 * floor(greatest(extract(epoch from now() - q.enqueued_at), extract(epoch from now() - mine.enqueued_at)) / 10)
    order by abs(q.rating - mine.rating), q.enqueued_at, q.uid limit 1;
  if not found then return jsonb_build_object('status', 'searching'); end if;

  am_host := (mine.enqueued_at, mine.uid) < (other.enqueued_at, other.uid);
  if p_protocol in (14, 15) then
    r := duanlian_private.make_room(pair, case when am_host then me else other.uid end,
      case when am_host then other.uid else me end, false, p_protocol);
    code := r.code;
  end if;
  assigned := jsonb_build_object('status', 'matched', 'pair', pair, 'code', code, 'host', am_host, 'peer', other.uid);
  update duanlian_private.mm_queue set assignment = assigned, assigned_at = now() where uid = me;
  update duanlian_private.mm_queue set assignment = assigned || jsonb_build_object('host', not am_host, 'peer', me),
    assigned_at = now() where uid = other.uid;
  return assigned;
end;
$$;

revoke all on function duanlian_private.make_room(uuid, uuid, uuid, boolean, integer) from public, anon, authenticated;
revoke all on function public.room_create(boolean, integer), public.room_enter(text, uuid, integer),
  public.room_invites(integer) from public, anon, authenticated;
grant execute on function public.room_create(boolean, integer), public.room_enter(text, uuid, integer),
  public.room_invites(integer) to authenticated;

notify pgrst, 'reload schema';

commit;

-- 《断链》v2.0：协议 16（破绽断链 + 新的掉落阶段）。协议号改成区间 14–30，以后改对战规则只需改客户端的 ONLINE_PROTOCOL。
-- 旧客户端（协议 14 / 15）照常可用，只和同协议的玩家匹配、进房。

begin;

alter table duanlian_private.rooms drop constraint if exists rooms_protocol_check;
alter table duanlian_private.rooms add constraint rooms_protocol_check check (protocol between 14 and 30);

create or replace function duanlian_private.make_room(p_id uuid, p_host uuid, p_guest uuid, p_spar boolean, p_protocol integer)
returns duanlian_private.rooms language plpgsql set search_path = pg_catalog as $$
declare
  r duanlian_private.rooms;
begin
  if p_protocol is null or p_protocol not between 14 and 30 then raise exception 'unsupported protocol'; end if;
  r := duanlian_private.make_room(p_id, p_host, p_guest, p_spar);
  update duanlian_private.rooms set protocol = p_protocol where id = r.id returning * into r;
  return r;
end;
$$;

create or replace function public.mm_join(p_protocol integer default 13)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
begin
  perform duanlian_private.check_limit(me, 'mm_join', 15);
  if p_protocol is null or p_protocol not between 13 and 30 then raise exception 'unsupported protocol'; end if;
  perform pg_advisory_xact_lock(479887002);
  insert into duanlian_private.mm_queue as q (uid, rating, protocol) select me, rating, p_protocol from public.profiles where id = me
    on conflict (uid) do update set seen_at = now(), rating = excluded.rating, protocol = excluded.protocol,
      enqueued_at = case when q.protocol = p_protocol and q.seen_at > now() - interval '8 seconds' and q.assignment is null
        then q.enqueued_at else now() end, assignment = null, assigned_at = null;
end;
$$;

create or replace function public.mm_poll(p_protocol integer default 13)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  me uuid := auth.uid();
  mine duanlian_private.mm_queue;
  other duanlian_private.mm_queue;
  pair uuid := gen_random_uuid();
  code text := (1000 + floor(random() * 9000)::integer)::text;
  am_host boolean;
  assigned jsonb;
  r duanlian_private.rooms;
begin
  perform duanlian_private.check_limit(me, 'mm_poll', 55);
  perform pg_advisory_xact_lock(479887002);
  delete from duanlian_private.mm_queue where
    (assignment is null and seen_at <= now() - interval '8 seconds') or assigned_at <= now() - interval '15 seconds';
  update duanlian_private.mm_queue set seen_at = now() where uid = me and protocol = p_protocol returning * into mine;
  if not found then return jsonb_build_object('status', 'idle'); end if;
  if mine.assignment is not null then return mine.assignment; end if;
  select * into other from duanlian_private.mm_queue q
    where q.uid <> me and q.protocol = p_protocol and q.assignment is null and abs(q.rating - mine.rating) <=
      100 + 100 * floor(greatest(extract(epoch from now() - q.enqueued_at), extract(epoch from now() - mine.enqueued_at)) / 10)
    order by abs(q.rating - mine.rating), q.enqueued_at, q.uid limit 1;
  if not found then return jsonb_build_object('status', 'searching'); end if;

  am_host := (mine.enqueued_at, mine.uid) < (other.enqueued_at, other.uid);
  if p_protocol between 14 and 30 then
    r := duanlian_private.make_room(pair, case when am_host then me else other.uid end,
      case when am_host then other.uid else me end, false, p_protocol);
    code := r.code;
  end if;
  assigned := jsonb_build_object('status', 'matched', 'pair', pair, 'code', code, 'host', am_host, 'peer', other.uid);
  update duanlian_private.mm_queue set assignment = assigned, assigned_at = now() where uid = me;
  update duanlian_private.mm_queue set assignment = assigned || jsonb_build_object('host', not am_host, 'peer', me),
    assigned_at = now() where uid = other.uid;
  return assigned;
end;
$$;

notify pgrst, 'reload schema';

commit;
