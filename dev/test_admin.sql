-- 在测试 Supabase 项目的 SQL Editor 或 psql 中运行。所有测试数据均回滚。
begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('ad000000-0000-4000-8000-000000000001', 'admtest_one@players.duanlian.game', '{"username":"admtest_one"}'),
  ('ad000000-0000-4000-8000-000000000002', 'admtest_two@players.duanlian.game', '{"username":"admtest_two"}'),
  ('ad000000-0000-4000-8000-000000000003', 'admtest_three@players.duanlian.game', '{"username":"admtest_three"}');
insert into duanlian_private.admin_members (uid) values ('ad000000-0000-4000-8000-000000000001');

insert into duanlian_private.rooms (id, code, host, guest, guest_until, protocol)
select ('ad000000-0000-4000-8100-00000000000' || row_number() over (order by s.code))::uuid, s.code,
  s.host, s.guest, s.expires, 18
from (
  select lpad(code::text, 4, '0') as code,
    case when row_number() over (order by code) = 1 then 'ad000000-0000-4000-8000-000000000001'::uuid
      else 'ad000000-0000-4000-8000-000000000002'::uuid end as host,
    case when row_number() over (order by code) = 2 then 'ad000000-0000-4000-8000-000000000003'::uuid end as guest,
    case when row_number() over (order by code) = 2 then now() + interval '90 seconds' end as expires
  from generate_series(0, 9999) code
  where not exists (select 1 from duanlian_private.rooms r where r.code = lpad(code::text, 4, '0'))
  order by code limit 2
) s;

set local role anon;
do $$
begin
  if has_function_privilege(current_user, 'public.dl_admin_overview()', 'EXECUTE') then
    raise exception 'anonymous overview allowed';
  end if;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'ad000000-0000-4000-8000-000000000002', true);
do $$
begin
  begin
    perform public.dl_admin_accounts('', 0);
    raise exception 'ordinary account can view player data';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.dl_admin_rooms();
    raise exception 'ordinary account can view rooms';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.dl_admin_audit(0);
    raise exception 'ordinary account can view audit data';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.dl_admin_close_room('ad000000-0000-4000-8100-000000000001', 'attempt');
    raise exception 'ordinary account can close rooms';
  exception when insufficient_privilege then null;
  end;
  if has_function_privilege(current_user, 'public.dl_admin_account_begin(uuid,uuid,text,text)', 'EXECUTE') then
    raise exception 'client can impersonate another operator';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub', 'ad000000-0000-4000-8000-000000000001', true);
do $$
declare
  snapshot jsonb := public.dl_admin_overview();
  entry jsonb;
begin
  if snapshot->>'actor' is distinct from 'admtest_one' or jsonb_array_length(snapshot->'trend') <> 12 then
    raise exception 'invalid overview';
  end if;
  if jsonb_array_length(public.dl_admin_accounts('ADMTEST_TWO', 0)) <> 1
    or jsonb_array_length(public.dl_admin_accounts('%', 0)) <> 0
    or jsonb_array_length(public.dl_admin_accounts('admtest', 2)) <> 1 then
    raise exception 'account filtering or pagination failed';
  end if;
  entry := public.dl_admin_accounts('ad000000-0000-4000-8000-000000000001', 0)->0;
  if entry->>'is_admin' is distinct from 'true' or entry ? 'email' then
    raise exception 'bad account shape';
  end if;
  begin
    perform public.dl_admin_close_room('ad000000-0000-4000-8100-000000000002', 'occupied');
    raise exception 'closed occupied room';
  exception when raise_exception then
    if sqlerrm <> 'room_unavailable' then raise; end if;
  end;
  perform public.dl_admin_close_room('ad000000-0000-4000-8100-000000000001', 'close test');
  if not exists (select 1 from jsonb_array_elements(public.dl_admin_audit(0)) a
    where a->>'action' = 'close_room' and a->>'reason' = 'close test' and a->>'status' = 'done') then
    raise exception 'no room audit record';
  end if;
end;
$$;

set local role service_role;
do $$
declare
  op uuid;
  actor constant uuid := 'ad000000-0000-4000-8000-000000000001';
  target constant uuid := 'ad000000-0000-4000-8000-000000000002';
begin
  begin
    perform public.dl_admin_account_begin(target, actor, 'ban', 'ordinary player');
    raise exception 'service action accepts non-admin actor';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.dl_admin_account_begin(actor, actor, 'ban', 'protected');
    raise exception 'an admin account is mutable';
  exception when insufficient_privilege then null;
  end;
  op := public.dl_admin_account_begin(actor, target, 'ban', 'ban test');
  begin
    perform public.dl_admin_account_begin(actor, target, 'ban', 'retry');
    raise exception 'parallel account action allowed';
  exception when raise_exception then
    if sqlerrm <> 'account_action_in_progress' then raise; end if;
  end;
  perform public.dl_admin_account_finish(op, 'done');
end;
$$;

reset role;
update auth.users set banned_until = now() + interval '1 day' where id = 'ad000000-0000-4000-8000-000000000002';

set local role service_role;
do $$
declare
  op uuid;
begin
  op := public.dl_admin_account_begin('ad000000-0000-4000-8000-000000000001',
    'ad000000-0000-4000-8000-000000000002', 'unban', 'unban test');
  perform public.dl_admin_account_finish(op, 'uncertain');
end;
$$;

set local role authenticated;
do $$
begin
  if not exists (select 1 from jsonb_array_elements(public.dl_admin_audit(0)) a
    where a->>'action' = 'unban' and a->>'reason' = 'unban test' and a->>'status' = 'uncertain') then
    raise exception 'uncertain account change missing from audit';
  end if;
end;
$$;

reset role;
delete from duanlian_private.admin_members where uid = 'ad000000-0000-4000-8000-000000000001';
set local role authenticated;
do $$
begin
  begin
    perform public.dl_admin_overview();
    raise exception 'old session kept access after admin access was revoked';
  exception when insufficient_privilege then null;
  end;
end;
$$;

rollback;
