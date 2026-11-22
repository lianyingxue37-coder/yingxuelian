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
