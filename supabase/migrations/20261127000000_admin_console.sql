-- 《断链》管理台。管理员由数据库管理员显式授权，游戏账号默认没有管理权限。
begin;

create table if not exists duanlian_private.admin_members (
  uid uuid primary key references auth.users (id) on delete cascade
);
create table if not exists duanlian_private.admin_audit (
  id uuid primary key default gen_random_uuid(),
  actor uuid not null,
  actor_name text not null,
  action text not null check (action in ('ban', 'unban', 'close_room')),
  target uuid not null,
  target_name text not null,
  reason text not null check (char_length(reason) between 1 and 240),
  status text not null check (status in ('pending', 'done', 'failed', 'uncertain')),
  created_at timestamptz not null default now()
);
alter table duanlian_private.admin_members enable row level security;
alter table duanlian_private.admin_audit enable row level security;
revoke all on duanlian_private.admin_members, duanlian_private.admin_audit from public, anon, authenticated;
create unique index if not exists admin_account_action_in_progress
  on duanlian_private.admin_audit (target) where status = 'pending';
create index if not exists admin_audit_recent on duanlian_private.admin_audit (created_at desc, id desc);
create index if not exists admin_games_recent on duanlian_private.games (opened_at desc);
create index if not exists admin_profiles_recent on public.profiles (created_at desc, id desc);

create or replace function duanlian_private.admin_require(p_uid uuid)
returns text language plpgsql stable set search_path = pg_catalog as $$
declare
  actor_name text;
begin
  select p.username into actor_name
  from duanlian_private.admin_members a
  join auth.users u on u.id = a.uid
  join public.profiles p on p.id = a.uid
  where a.uid = p_uid and (u.banned_until is null or u.banned_until <= now());
  if not found then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  return actor_name;
end;
$$;
revoke all on function duanlian_private.admin_require(uuid) from public, anon, authenticated;

create or replace function public.dl_admin_overview()
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
declare
  actor_name text := duanlian_private.admin_require(auth.uid());
  start_hour timestamptz := date_trunc('hour', now()) - interval '23 hours';
  recent_games jsonb;
begin
  select jsonb_agg(jsonb_build_object('at', bucket, 'count', total) order by bucket)
    into recent_games
  from (
    select t.bucket, count(g.id) as total
    from generate_series(start_hour, start_hour + interval '22 hours', interval '2 hours') as t(bucket)
    left join duanlian_private.games g on g.opened_at >= t.bucket and g.opened_at < t.bucket + interval '2 hours'
    group by t.bucket
  ) bins;
  return jsonb_build_object(
    'actor', actor_name, 'at', now(), 'trend', recent_games,
    'players', (select count(*) from public.profiles),
    'new_players', (select count(*) from public.profiles where created_at >= now() - interval '24 hours'),
    'rooms', (select count(*) from duanlian_private.rooms where host_until > now()),
    'queued', (select count(*) from duanlian_private.mm_queue where assignment is null and seen_at > now() - interval '8 seconds'),
    'games', (select count(*) from duanlian_private.games where opened_at >= now() - interval '24 hours'),
    'verified', (select count(*) from duanlian_private.games where opened_at >= now() - interval '24 hours' and status = 'verified'),
    'disputed', (select count(*) from duanlian_private.games where opened_at >= now() - interval '24 hours' and status = 'disputed'),
    'pending', (select count(*) from duanlian_private.games
      where status = 'pending' and opened_at > now() - interval '2 hours'
      and (first_report_at is null or first_report_at > now() - interval '10 minutes'))
  );
end;
$$;

create or replace function public.dl_admin_accounts(p_query text default '', p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
declare
  q text := lower(btrim(coalesce(p_query, '')));
begin
  perform duanlian_private.admin_require(auth.uid());
  if char_length(q) > 80 or p_offset is null or p_offset < 0 then
    raise exception 'invalid_page' using errcode = '22023';
  end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc, a.id desc), '[]'::jsonb)
    from (
      select p.id, p.username, p.nickname, p.rating, p.created_at, u.last_sign_in_at, u.banned_until,
        exists (select 1 from duanlian_private.admin_members m where m.uid = p.id) as is_admin
      from public.profiles p join auth.users u on u.id = p.id
      where q = '' or strpos(p.username, q) > 0 or strpos(lower(p.nickname), q) > 0 or p.id::text = q
      order by p.created_at desc, p.id desc offset p_offset limit 21
    ) a
  );
end;
$$;

create or replace function public.dl_admin_rooms()
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.admin_require(auth.uid());
  return (
    select coalesce(jsonb_agg(to_jsonb(r) order by r.host_until desc, r.id), '[]'::jsonb)
    from (
      select r.id, r.code, h.username as host, g.username as guest,
        r.protocol, r.spar, r.matched, r.host_until,
        (r.guest is null and not r.matched) as can_close
      from duanlian_private.rooms r
      join public.profiles h on h.id = r.host
      left join public.profiles g on g.id = r.guest and r.guest_until > now()
      where r.host_until > now()
      order by r.host_until desc, r.id limit 50
    ) r
  );
end;
$$;

create or replace function public.dl_admin_audit(p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.admin_require(auth.uid());
  if p_offset is null or p_offset < 0 then
    raise exception 'invalid_page' using errcode = '22023';
  end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc, a.id desc), '[]'::jsonb)
    from (
      select id, actor_name, action, target_name, reason, created_at,
        case when status = 'pending' and created_at <= now() - interval '2 minutes' then 'uncertain' else status end as status
      from duanlian_private.admin_audit
      order by created_at desc, id desc offset p_offset limit 21
    ) a
  );
end;
$$;

create or replace function public.dl_admin_close_room(p_room uuid, p_reason text)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare
  actor uuid := auth.uid();
  actor_name text := duanlian_private.admin_require(actor);
  room_code text;
begin
  if coalesce(char_length(btrim(p_reason)), 0) not between 1 and 240 then
    raise exception 'invalid_reason' using errcode = '22023';
  end if;
  delete from duanlian_private.rooms
  where id = p_room and guest is null and not matched and host_until > now()
  returning code into room_code;
  if not found then
    raise exception 'room_unavailable';
  end if;
  insert into duanlian_private.admin_audit (actor, actor_name, action, target, target_name, reason, status)
  values (actor, actor_name, 'close_room', p_room, room_code, btrim(p_reason), 'done');
end;
$$;

-- 只有在 Edge Function 已用 Auth 验证用户令牌之后，才能用 service_role 创建管理操作。
create or replace function public.dl_admin_account_begin(p_actor uuid, p_target uuid, p_action text, p_reason text)
returns uuid language plpgsql security definer set search_path = pg_catalog as $$
declare
  actor_name text := duanlian_private.admin_require(p_actor);
  target_name text;
  blocked_until timestamptz;
  audit_id uuid;
begin
  if p_target is null or p_action is null or p_action not in ('ban', 'unban')
    or coalesce(char_length(btrim(p_reason)), 0) not between 1 and 240 then
    raise exception 'invalid_account_action' using errcode = '22023';
  end if;
  if exists (select 1 from duanlian_private.admin_members where uid = p_target) then
    raise exception 'protected_account' using errcode = '42501';
  end if;

  select p.username, u.banned_until into target_name, blocked_until
  from public.profiles p join auth.users u on u.id = p.id where p.id = p_target for update of u;
  if not found then raise exception 'account_not_found'; end if;
  if coalesce(blocked_until > now(), false) = (p_action = 'ban') then
    raise exception 'account_state_changed';
  end if;

  perform duanlian_private.check_limit(p_actor, 'dl_admin_account', 20);
  update duanlian_private.admin_audit set status = 'uncertain'
    where target = p_target and status = 'pending' and created_at <= now() - interval '2 minutes';
  insert into duanlian_private.admin_audit (actor, actor_name, action, target, target_name, reason, status)
    values (p_actor, actor_name, p_action, p_target, target_name, btrim(p_reason), 'pending')
    on conflict (target) where status = 'pending' do nothing returning id into audit_id;
  if not found then raise exception 'account_action_in_progress'; end if;
  return audit_id;
end;
$$;

create or replace function public.dl_admin_account_finish(p_id uuid, p_outcome text)
returns void language plpgsql security definer set search_path = pg_catalog as $$
begin
  if p_outcome is null or p_outcome not in ('done', 'failed', 'uncertain') then
    raise exception 'invalid_audit_outcome' using errcode = '22023';
  end if;
  update duanlian_private.admin_audit set status = p_outcome
    where id = p_id and action in ('ban', 'unban') and status = 'pending';
  if not found then raise exception 'audit_action_not_pending'; end if;
end;
$$;

revoke all on function public.dl_admin_overview(), public.dl_admin_accounts(text, integer),
  public.dl_admin_rooms(), public.dl_admin_audit(integer), public.dl_admin_close_room(uuid, text)
  from public, anon, authenticated;
grant execute on function public.dl_admin_overview(), public.dl_admin_accounts(text, integer),
  public.dl_admin_rooms(), public.dl_admin_audit(integer), public.dl_admin_close_room(uuid, text)
  to authenticated;

revoke all on function public.dl_admin_account_begin(uuid, uuid, text, text), public.dl_admin_account_finish(uuid, text)
  from public, anon, authenticated;
grant execute on function public.dl_admin_account_begin(uuid, uuid, text, text),
  public.dl_admin_account_finish(uuid, text) to service_role;

notify pgrst, 'reload schema';
commit;
