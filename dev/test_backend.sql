-- 在测试项目的 SQL Editor 或 psql 中运行。测试账户和数据在事务回滚后消失。
begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('de000000-0000-4000-8000-000000000001', 'v2test_a@players.duanlian.game', '{"username":"v2test_a"}'),
  ('de000000-0000-4000-8000-000000000002', 'v2test_b@players.duanlian.game', '{"username":"v2test_b"}'),
  ('de000000-0000-4000-8000-000000000003', 'v2test_c@players.duanlian.game', '{"username":"v2test_c"}');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'de000000-0000-4000-8000-000000000001', true);
do $$
begin
  begin
    update public.profiles set stats = '{"onG":99}' where id = auth.uid();
    raise exception 'protected stats allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.profiles set achievements = '{}' where id = auth.uid();
    raise exception 'protected achievements allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.profiles set rating = 9999 where id = auth.uid();
    raise exception 'protected rating allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.matches (mode, result, verified) values ('online', 'win', true);
    raise exception 'direct match write allowed';
  exception when insufficient_privilege then null;
  end;
  update public.profiles set nickname = '测试甲', avatar = 'CH_SHUANG', title = 'ACH_CPU2' where id = auth.uid();
  if not found then raise exception 'own cosmetic edit denied'; end if;
  update public.profiles set nickname = '测试乙' where id <> auth.uid() and username = 'v2test_b';
  if found then raise exception 'another player can edit a nickname'; end if;
end;
$$;

select public.record_cpu_match('CH_JIN', 'CH_LAN', 'win', '2:0', 10, 1, 'STG_01', '普通');
do $$
begin
  if not exists (select 1 from public.matches where mode = 'cpu' and not verified and user_id = auth.uid())
     or exists (select 1 from public.duanlian_leaderboard where nickname = '测试甲') then
    raise exception 'invalid CPU persistence';
  end if;
end;
$$;

select public.online_open(g, '1200', 'de000000-0000-4000-8000-000000000002',
  '{"seed":1,"D":8,"sel":{"p1":"CH_JIN","p2":"CH_LAN","stage":"STG_01"},"cfg":{}}')
from (values
  ('de000000-0000-4000-8100-000000000001'::uuid), ('de000000-0000-4000-8100-000000000002'::uuid),
  ('de000000-0000-4000-8100-000000000003'::uuid)
) as ids(g);

do $$
declare
  report jsonb := '[{"rounds":2,"hits":25,"level":4},{"rounds":1,"hits":5,"level":1}]';
  first uuid := 'de000000-0000-4000-8100-000000000001';
  second uuid := 'de000000-0000-4000-8100-000000000002';
  third uuid := 'de000000-0000-4000-8100-000000000003';
  data jsonb;
begin
  if not public.can_join_duanlian_game('duanlian-game:' || first) then raise exception 'host channel denied'; end if;
  data := public.submit_online_result(first, 600, 4294967295, 0, report);
  if data->>'status' is distinct from 'pending' then raise exception 'first report must be pending'; end if;
  data := public.submit_online_result(first, 601, 3, 0, report);
  if data->>'status' is distinct from 'pending' then raise exception 'duplicate altered first report'; end if;
  perform public.submit_online_result(second, 601, 3, 0, report);
  perform public.submit_online_result(third, 700, 42, 0, report);
  if exists (select 1 from public.matches where verified) then raise exception 'unilateral verification'; end if;

  perform set_config('request.jwt.claim.sub', 'de000000-0000-4000-8000-000000000003', true);
  if public.online_game(first) is not null or public.can_join_duanlian_game('duanlian-game:' || first) then
    raise exception 'third player has access to game';
  end if;
  begin
    perform public.submit_online_result(first, 600, 4294967295, 0, report);
    raise exception 'third player can submit a result';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', 'de000000-0000-4000-8000-000000000002', true);
  data := public.submit_online_result(first, 600, 4294967295, 0, report);
  if data->>'status' is distinct from 'verified' or data #>> '{stats,onG}' is distinct from '1'
    or data ->> 'rating' is distinct from '984' then raise exception 'consistent reports did not verify: %', data; end if;
  data := public.submit_online_result(second, 602, 3, 0, report);
  if data->>'status' is distinct from 'disputed' then raise exception 'mismatched reports must be disputed'; end if;
  data := public.submit_online_result(second, 601, 3, 0, report);
  if data->>'status' is distinct from 'disputed' then raise exception 'disputed result changed'; end if;
  if (select count(*) from public.matches where verified) <> 1 then raise exception 'guest records: not exactly one'; end if;

  perform set_config('request.jwt.claim.sub', 'de000000-0000-4000-8000-000000000001', true);
  data := public.submit_online_result(first, 600, 4294967295, 0, report);
  if data->>'status' is distinct from 'verified' or data #>> '{stats,onG}' is distinct from '1'
     or data #>> '{stats,maxHits}' is distinct from '25' or data #>> '{achievements,ACH_HIT25}' is distinct from 'true'
     or data ->> 'rating' is distinct from '1016' then raise exception 'incorrect verified stats: %', data; end if;
  if (select count(*) from public.matches where verified) <> 1 then raise exception 'host records: not exactly one'; end if;
  if not exists (select 1 from public.duanlian_leaderboard where nickname = '测试甲' and wins = 1 and win_rate = 100) then
    raise exception 'leaderboard missing host result';
  end if;
end;
$$;

reset role;
update duanlian_private.games set first_report_at = now() - interval '11 minutes'
  where id = 'de000000-0000-4000-8100-000000000003';
-- Isolate matchmaking from any queue entries already on this test instance.
delete from duanlian_private.mm_queue;
update public.profiles set rating = 750 where username = 'v2test_c';
set local role authenticated;
select set_config('request.jwt.claim.sub', 'de000000-0000-4000-8000-000000000002', true);

do $$
declare
  data jsonb;
begin
  data := public.submit_online_result('de000000-0000-4000-8100-000000000003', 700, 42, 0,
    '[{"rounds":2,"hits":25,"level":4},{"rounds":1,"hits":5,"level":1}]');
  if data->>'status' is distinct from 'expired' then raise exception 'late submissions must expire'; end if;
  perform public.mm_join();
  perform set_config('request.jwt.claim.sub', 'de000000-0000-4000-8000-000000000003', true);
  perform public.mm_join();
  data := public.mm_poll();
  if data->>'status' is distinct from 'searching' then raise exception 'matched outside initial Elo window'; end if;
end;
$$;

reset role;
update duanlian_private.mm_queue set enqueued_at = now() - interval '20 seconds';
set local role authenticated;
do $$
declare
  c jsonb := public.mm_poll();
  b jsonb;
begin
  if c->>'status' is distinct from 'matched' then raise exception 'Elo window did not expand'; end if;
  perform set_config('request.jwt.claim.sub', 'de000000-0000-4000-8000-000000000002', true);
  b := public.mm_poll();
  if c->>'pair' is distinct from b->>'pair' or c->>'host' is not distinct from b->>'host'
     or c->>'peer' is distinct from 'de000000-0000-4000-8000-000000000002'
  then raise exception 'players did not receive complementary assignments'; end if;
  perform public.mm_leave();
  if public.mm_poll()->>'status' is distinct from 'idle' then raise exception 'cancelled user still queued'; end if;
end;
$$;

do $$
begin
  for i in 1..15 loop perform public.mm_join(); end loop;
  raise exception 'RPC limit did not apply';
exception when raise_exception then
  if sqlerrm <> 'rate limit exceeded' then raise; end if;
end;
$$;

-- 好友与好友切磋：只能以自己名义发请求，只有对方能同意，切磋局不计分。
reset role;
set local role authenticated;
do $$
declare
  a uuid := 'de000000-0000-4000-8000-000000000001';
  b uuid := 'de000000-0000-4000-8000-000000000002';
  c uuid := 'de000000-0000-4000-8000-000000000003';
  spar uuid := 'de000000-0000-4000-8100-000000000009';
  report jsonb := '[{"rounds":1,"hits":3,"level":1},{"rounds":0,"hits":2,"level":0}]';
  fid bigint;
  data jsonb;
begin
  perform set_config('request.jwt.claim.sub', a::text, true);
  begin
    insert into public.friendships (requester, addressee) values (b, c);
    raise exception 'request on behalf of another user allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.friendships (addressee, status) values (b, 'accepted');
    raise exception 'pre-accepted request allowed';
  exception when insufficient_privilege then null;
  end;
  insert into public.friendships (addressee) values (b) returning id into fid;
  begin
    insert into public.friendships (requester, addressee) values (a, b);
    raise exception 'duplicate request allowed';
  exception when unique_violation then null;
  end;
  update public.friendships set status = 'accepted' where id = fid;
  if found then raise exception 'requester accepted own request'; end if;

  perform set_config('request.jwt.claim.sub', c::text, true);
  if exists (select 1 from public.friendships) then raise exception 'third party can read friendships'; end if;
  delete from public.friendships where id = fid;
  if found then raise exception 'third party deleted a friendship'; end if;

  perform set_config('request.jwt.claim.sub', b::text, true);
  begin
    update public.friendships set requester = c where id = fid;
    raise exception 'addressee rewrote requester';
  exception when insufficient_privilege then null;
  end;
  update public.friendships set status = 'accepted' where id = fid;
  if not found then raise exception 'addressee could not accept'; end if;

  perform public.online_open(spar, '4321', a,
    '{"seed":1,"D":8,"spar":true,"sel":{"p1":"CH_JIN","p2":"CH_LAN","stage":"STG_01"},"cfg":{"ROUNDS_TO_WIN":1}}');
  data := public.submit_online_result(spar, 600, 7, 0, report);
  if data->>'status' is distinct from 'unrated' then raise exception 'spar game was rated: %', data; end if;
  perform set_config('request.jwt.claim.sub', a::text, true);
  data := public.submit_online_result(spar, 600, 7, 0, report);
  if data->>'status' is distinct from 'unrated' or exists (select 1 from public.matches where game_id = spar) then
    raise exception 'spar game recorded: %', data;
  end if;

  delete from public.friendships where id = fid;
  if not found then raise exception 'friend could not delete'; end if;
end;
$$;

reset role;
insert into duanlian_private.rpc_limits (uid, route, bucket, calls)
  values ('de000000-0000-4000-8000-000000000001', 'friend_request', date_trunc('minute', clock_timestamp()), 20)
  on conflict (uid, route) do update set bucket = excluded.bucket, calls = excluded.calls;
set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claim.sub', 'de000000-0000-4000-8000-000000000001', true);
  insert into public.friendships (addressee) values ('de000000-0000-4000-8000-000000000003');
  raise exception 'friend request limit did not apply';
exception when raise_exception then
  if sqlerrm <> 'rate limit exceeded' then raise; end if;
end;
$$;

-- 房间席位、邀请隐私、好友限制，以及新旧协议分开匹配。
do $$
declare
  a uuid := 'de000000-0000-4000-8000-000000000001';
  b uuid := 'de000000-0000-4000-8000-000000000002';
  c uuid := 'de000000-0000-4000-8000-000000000003';
  game uuid := 'de000000-0000-4000-8100-000000000010';
  setup jsonb := '{"seed":1,"D":8,"spar":false,"sel":{"p1":"CH_JIN","p2":"CH_LAN","stage":"STG_01"},"cfg":{}}';
  r jsonb;
  rm uuid;
  code text;
  fid bigint;
  ticket jsonb;
begin
  perform set_config('request.jwt.claim.sub', a::text, true);
  r := public.room_create(false);
  rm := (r->>'id')::uuid; code := r->>'code';
  if not public.can_join_duanlian_room('duanlian-room:' || rm)
    or not public.room_invite(rm, b) then raise exception 'host failed to create or send an invite'; end if;

  perform set_config('request.jwt.claim.sub', c::text, true);
  if public.room_invites() <> '[]' or public.can_join_duanlian_room('duanlian-room:' || rm)
    or public.room_touch(rm) is not null or public.room_enter(code)->>'status' is distinct from 'reserved'
  then raise exception 'non-recipient gained an invite or room seat'; end if;

  perform set_config('request.jwt.claim.sub', b::text, true);
  if public.room_invites() #>> '{0,id}' is distinct from rm::text then raise exception 'recipient invite missing'; end if;
  r := public.room_enter(code, rm);
  if r->>'guest' is distinct from b::text or not public.can_join_duanlian_room('duanlian-room:' || rm) then
    raise exception 'recipient could not join and use private channel';
  end if;
  begin
    perform public.room_start(rm, game, setup);
    raise exception 'guest started the room';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', c::text, true);
  if public.room_enter(code)->>'status' is distinct from 'full' then raise exception 'third player took occupied seat'; end if;
  perform set_config('request.jwt.claim.sub', a::text, true);
  if public.room_start(rm, game, setup) is distinct from game then raise exception 'host failed to start'; end if;
  perform set_config('request.jwt.claim.sub', b::text, true);
  if public.online_game(game)->>'guest' is distinct from b::text then raise exception 'wrong guest bound to game'; end if;
  perform public.room_exit(rm);
  if public.can_join_duanlian_room('duanlian-room:' || rm) then raise exception 'former guest retained room access'; end if;

  perform set_config('request.jwt.claim.sub', a::text, true);
  if public.room_touch(rm)->>'guest' is not null then raise exception 'guest seat did not release'; end if;
  perform public.room_exit(rm);
  if public.room_enter(code)->>'status' is distinct from 'missing' then raise exception 'closed room code still active'; end if;

  delete from public.friendships where requester = a and addressee = b;
  -- The previous rate-limit assertion fills A's counter for friend requests; B sends this one.
  perform set_config('request.jwt.claim.sub', b::text, true);
  insert into public.friendships (addressee) values (a) returning id into fid;
  perform set_config('request.jwt.claim.sub', a::text, true);
  update public.friendships set status = 'accepted' where id = fid;
  r := public.room_create(true); rm := (r->>'id')::uuid; code := r->>'code';
  if public.room_invite(rm, c) or not public.room_invite(rm, b) then raise exception 'spar invite membership incorrect'; end if;
  perform set_config('request.jwt.claim.sub', c::text, true);
  if public.room_enter(code)->>'status' is distinct from 'friends_only' then raise exception 'stranger joined friends-only room'; end if;
  perform set_config('request.jwt.claim.sub', b::text, true);
  perform public.room_decline(rm);
  if public.room_invites() <> '[]' then raise exception 'declined invite remains visible'; end if;
  if public.room_enter(code)->>'spar' is distinct from 'true' then raise exception 'friend could not join spar'; end if;
  perform public.room_exit(rm);

  perform public.mm_leave();
  perform set_config('request.jwt.claim.sub', c::text, true);
  perform public.mm_leave();
  perform set_config('request.jwt.claim.sub', a::text, true);
  perform public.room_exit(rm);
  perform public.mm_join(14);
  perform set_config('request.jwt.claim.sub', b::text, true);
  perform public.mm_join(13);
  perform set_config('request.jwt.claim.sub', a::text, true);
  if public.mm_poll(14)->>'status' is distinct from 'searching' then raise exception 'mixed queue protocols matched'; end if;
  perform set_config('request.jwt.claim.sub', b::text, true);
  perform public.mm_join(14); ticket := public.mm_poll(14);
  if ticket->>'status' is distinct from 'matched' or not public.can_join_duanlian_room('duanlian-room:' || (ticket->>'pair')) then
    raise exception 'matchmaking did not produce a private room';
  end if;
  perform set_config('request.jwt.claim.sub', c::text, true);
  if public.can_join_duanlian_room('duanlian-room:' || (ticket->>'pair'))
    or public.room_enter(ticket->>'code')->>'status' is distinct from 'full' then raise exception 'third party claimed a ranked seat'; end if;
end;
$$;

reset role;
rollback;
select 'backend, friends and rooms assertions passed' as verification;
