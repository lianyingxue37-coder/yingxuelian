-- 管理后台（gm_*）数据库测试：psql -v ON_ERROR_STOP=1 -f dev/test_gm.sql（整段回滚，不留数据）
begin;
insert into auth.users (id, email, raw_user_meta_data) values
  ('6a000001-0000-0000-0000-000000000001', 'gmtest_owner@players.duanlian.game', '{"username":"gmtest_owner","nickname":"站长"}'),
  ('6a000002-0000-0000-0000-000000000002', 'gmtest_admin@players.duanlian.game', '{"username":"gmtest_admin","nickname":"管理"}'),
  ('6a000003-0000-0000-0000-000000000003', 'gmtest_p1@players.duanlian.game', '{"username":"gmtest_p1","nickname":"玩家一"}'),
  ('6a000004-0000-0000-0000-000000000004', 'gmtest_p2@players.duanlian.game', '{"username":"gmtest_p2","nickname":"玩家二"}');
insert into auth.sessions (user_id) values ('6a000003-0000-0000-0000-000000000003'), ('6a000003-0000-0000-0000-000000000003');
insert into duanlian_private.gm_admins (uid, role) values ('6a000001-0000-0000-0000-000000000001', 'owner') on conflict (uid) do update set role = 'owner';
insert into public.matches (user_id, mode, my_char, opp_char, result) values ('6a000003-0000-0000-0000-000000000003', 'cpu', 'CH_JIN', 'CH_LAN', 'win');

-- 普通玩家什么都调不了
set local role authenticated;
select set_config('request.jwt.claim.sub', '6a000003-0000-0000-0000-000000000003', true);
do $$ begin
  begin perform public.gm_me(); raise exception 'player passed gm_me'; exception when insufficient_privilege then null; end;
  begin perform public.gm_ban('6a000004-0000-0000-0000-000000000004', 1, 'x'); raise exception 'player banned'; exception when insufficient_privilege then null; end;
  begin perform public.gm_item(array['6a000003-0000-0000-0000-000000000003']::uuid[], 'SHOP_PATRON', 'grant', 'x'); raise exception 'player self-granted'; exception when insufficient_privilege then null; end;
  begin perform * from duanlian_private.gm_log; raise exception 'player read log'; exception when insufficient_privilege then null; end;
end $$;
-- 匿名：连函数都没有执行权限
reset role; set local role anon;
do $$ begin
  begin perform public.gm_overview(); raise exception 'anon ran gm'; exception when insufficient_privilege then null; end;
end $$;
reset role;

-- 站长
set local role authenticated;
select set_config('request.jwt.claim.sub', '6a000001-0000-0000-0000-000000000001', true);
do $$
declare r jsonb; u timestamptz;
  p1 uuid := '6a000003-0000-0000-0000-000000000003'; p2 uuid := '6a000004-0000-0000-0000-000000000004'; adm uuid := '6a000002-0000-0000-0000-000000000002';
begin
  r := public.gm_me(); assert r->>'role' = 'owner', 'me';
  r := public.gm_overview(); assert (r->>'players')::int >= 4, 'overview';
  r := public.gm_players('gmtest_', 'new', 0); assert (r->>'total')::int = 4 and jsonb_array_length(r->'rows') = 4, 'search';
  r := public.gm_players('玩家一', 'rating', 0); assert (r->>'total')::int = 1, 'search nickname';
  r := public.gm_players(p1::text, 'new', 0); assert r->'rows'->0->>'username' = 'gmtest_p1', 'search uuid';

  -- 理由必填
  begin perform public.gm_kick(p1, '  '); raise exception 'no reason accepted'; exception when invalid_parameter_value then null; end;

  -- 物品：批量发、重复发跳过、回收清掉佩戴的称号
  r := public.gm_item(array[p1, p2, '6a0000ff-0000-0000-0000-0000000000ff']::uuid[], 'SHOP_PATRON', 'grant', '活动奖励');
  assert (r->>'changed')::int = 2 and (r->>'skipped')::int = 1, 'bulk grant ' || r::text;
  r := public.gm_item(array[p1]::uuid[], 'SHOP_PATRON', 'grant', '再发一次'); assert (r->>'changed')::int = 0, 'dup grant';
  perform public.gm_player_edit(p1, null, null, 'SHOP_PATRON', null, '帮忙佩戴');
  assert (select title from public.profiles where id = p1) = 'SHOP_PATRON', 'title worn';
  r := public.gm_item(array[p1]::uuid[], 'SHOP_PATRON', 'revoke', '发错了'); assert (r->>'changed')::int = 1, 'revoke';
  assert (select title from public.profiles where id = p1) is null, 'title cleared on revoke';
  assert not exists (select 1 from public.inventory where uid = p1), 'inventory gone';
  begin perform public.gm_item(array[p1]::uuid[], 'SHOP_NOPE', 'grant', 'x'); raise exception 'bad item'; exception when raise_exception then if sqlerrm <> 'item_not_found' then raise; end if; end;

  -- 资料
  perform public.gm_player_edit(p1, '改名了', 'CH_LEI', null, 1500, '违规昵称');
  assert (select nickname || avatar || rating from public.profiles where id = p1) = '改名了CH_LEI1500', 'edit';
  begin perform public.gm_player_edit(p1, null, 'CH_NOPE', null, null, 'x'); raise exception 'bad avatar'; exception when check_violation then null; end;
  begin perform public.gm_player_edit(p1, null, null, 'SHOP_DUANLIAN', null, 'x'); raise exception 'unowned shop title'; exception when insufficient_privilege then null; end;

  -- 成就
  perform public.gm_achievement(p1, 'ACH_WIN50', 'grant', '补发');
  assert (select achievements ? 'ACH_WIN50' from public.profiles where id = p1), 'ach grant';
  perform public.gm_player_edit(p1, null, null, 'ACH_WIN50', null, '佩戴');
  perform public.gm_achievement(p1, 'ACH_WIN50', 'revoke', '收回');
  assert (select not (achievements ? 'ACH_WIN50') and title is null from public.profiles where id = p1), 'ach revoke';

  -- 封号 / 解封 / 踢下线
  u := public.gm_ban(p1, 24, '外挂'); assert u > now() + interval '23 hours', 'ban until';
  r := public.gm_player(p1); assert (r->>'banned')::boolean and (r->>'sessions')::int = 0 and jsonb_array_length(r->'log') >= 5, 'banned + kicked ' || r::text;
  u := public.gm_ban(p1, -1, '永久'); assert u = 'infinity', 'perma';
  u := public.gm_ban(p1, 0, '申诉通过'); assert u is null and public.gm_player(p1)->>'banned_until' is null, 'unban';
  begin perform public.gm_ban('6a000001-0000-0000-0000-000000000001', 1, 'x'); raise exception 'self ban'; exception when insufficient_privilege then null; end;
  assert public.gm_kick(p2, '卡房间') = 0, 'kick';

  -- 清战绩
  perform public.gm_reset_record(p1, '刷分');
  assert not exists (select 1 from public.matches where user_id = p1) and (select rating from public.profiles where id = p1) = 1000, 'reset';

  -- 商品
  perform public.gm_item_save('SHOP_GMTEST', 'title', '测试称号', '后台建的', 50, 99, true, '新活动');
  r := public.gm_catalog(); assert r @> '[{"id":"SHOP_GMTEST","price_coins":50}]', 'catalog';
  perform public.gm_item_save('SHOP_GMTEST', 'title', '测试称号', '下架', null, 99, false, '活动结束');
  assert public.gm_catalog() @> '[{"id":"SHOP_GMTEST","active":false}]', 'deactivate';

  -- 公告
  perform public.gm_announce(null, '今晚 10 点维护', 'warn', 2, null);
  r := public.gm_announcements(); assert jsonb_array_length(r) >= 1, 'announcements';

  -- 管理员：站长加一个普通管理员
  perform public.gm_admin_set('gmtest_admin', 'admin', '新同事');
  r := public.gm_admins(); assert jsonb_array_length(r) >= 2, 'admins';
  begin perform public.gm_admin_set('gmtest_owner', '', 'x'); raise exception 'removed self'; exception when insufficient_privilege then null; end;

  r := public.gm_log(null, 0); assert jsonb_array_length(r) >= 15, 'log ' || jsonb_array_length(r);
  r := public.gm_matches(0); assert r ? 'games' and r ? 'rooms', 'matches';
end $$;

-- 普通管理员：能管玩家，不能动管理员名单，也不能封其他管理员
select set_config('request.jwt.claim.sub', '6a000002-0000-0000-0000-000000000002', true);
do $$ begin
  perform public.gm_kick('6a000004-0000-0000-0000-000000000004', '测试');
  begin perform public.gm_admin_set('gmtest_p2', 'admin', 'x'); raise exception 'admin added admin'; exception when insufficient_privilege then null; end;
  begin perform public.gm_ban('6a000001-0000-0000-0000-000000000001', 1, 'x'); raise exception 'admin banned owner'; exception when insufficient_privilege then null; end;
end $$;

-- 公告：玩家只看得到生效中的
select set_config('request.jwt.claim.sub', '6a000003-0000-0000-0000-000000000003', true);
do $$ begin
  assert (select count(*) from public.announcements where body = '今晚 10 点维护') = 1, 'player sees live announcement';
  begin insert into public.announcements (body) values ('hack'); raise exception 'player posted'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'gm tests passed' as result;
rollback;
