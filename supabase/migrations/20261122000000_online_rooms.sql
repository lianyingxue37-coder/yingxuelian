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
