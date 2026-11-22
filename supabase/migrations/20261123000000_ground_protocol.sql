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
