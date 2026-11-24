-- 测试库中验证逐账户授权、订单权益保护、全服消息与语音授权。
begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('ad280000-0000-4000-8000-000000000001', 'ops_test@players.duanlian.game', '{"username":"ops_test"}'),
  ('ad280000-0000-4000-8000-000000000002', 'p2_test@players.duanlian.game', '{"username":"p2_test","nickname":"玩家二"}'),
  ('ad280000-0000-4000-8000-000000000003', 'p3_test@players.duanlian.game', '{"username":"p3_test"}');
insert into duanlian_private.admin_members values ('ad280000-0000-4000-8000-000000000001');
insert into public.inventory (uid, item_id) values ('ad280000-0000-4000-8000-000000000002', 'SHOP_ZHONGYAN');

set local role anon;
do $$
begin
  if has_table_privilege(current_user, 'public.world_chat', 'SELECT')
    or has_function_privilege(current_user, 'public.dl_world_voice_authorize()', 'EXECUTE')
    or has_function_privilege(current_user, 'public.dl_world_chat_post(text)', 'EXECUTE') then
    raise exception 'anonymous communication authorized';
  end if;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', 'ad280000-0000-4000-8000-000000000002', true);
do $$
declare posted jsonb;
begin
  if has_table_privilege(current_user, 'public.world_chat', 'INSERT')
    or has_table_privilege(current_user, 'public.inventory', 'INSERT') then raise exception 'direct client write allowed'; end if;
  begin
    perform public.dl_admin_player_update(auth.uid(), 'grant_item', 'forged', 'SHOP_PORTRAITS');
    raise exception 'player can grant their own inventory';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.dl_admin_player(auth.uid());
    raise exception 'player can use admin detail';
  exception when insufficient_privilege then null;
  end;
  posted := public.dl_world_chat_post('  <b> 你好 </b> ');
  if posted->>'nickname' <> '玩家二' or posted->>'message' <> '<b> 你好 </b>' or (posted->>'uid')::uuid <> auth.uid() then
    raise exception 'sender or plain text was not correctly recorded';
  end if;
  perform public.dl_world_voice_authorize();
end;
$$;

select set_config('request.jwt.claim.sub', 'ad280000-0000-4000-8000-000000000001', true);
do $$
declare target constant uuid := 'ad280000-0000-4000-8000-000000000002'; details jsonb;
begin
  perform public.dl_admin_player_update(target, 'grant_item', '活动赠予', 'SHOP_PORTRAITS');
  perform public.dl_admin_player_update(target, 'grant_item', '活动赠予重试', 'SHOP_PORTRAITS');
  perform public.dl_admin_player_update(target, 'grant_item', '活动赠予', 'SHOP_DUANLIAN');
  perform public.dl_admin_player_update(target, 'edit_profile', '更新头像', '林风', 'CH_YUE');
  perform public.dl_admin_player_update(target, 'mute_chat', '文字发言处理');
  begin
    perform public.dl_admin_player_update(target, 'revoke_item', '不允许收回原权益', 'SHOP_ZHONGYAN');
    raise exception 'order item could be revoked';
  exception when raise_exception then
    if sqlerrm <> 'item_not_admin_granted' then raise; end if;
  end;
  details := public.dl_admin_player(target);
  if details->>'nickname' <> '林风' or details->>'avatar' <> 'CH_YUE'
    or details->>'muted' <> 'true' or jsonb_array_length(details->'inventory') <> 3 then
    raise exception 'administration changes missing';
  end if;
  if exists (select 1 from jsonb_array_elements(public.dl_admin_audit(0)) a
    where a->>'reason' = '活动赠予重试') then raise exception 'duplicate grant audited as new'; end if;
  begin
    perform public.dl_admin_player_update(auth.uid(), 'grant_item', '管理员保护', 'SHOP_PORTRAITS');
    raise exception 'administrator protection missing';
  exception when insufficient_privilege then null;
  end;
end;
$$;

select set_config('request.jwt.claim.sub', 'ad280000-0000-4000-8000-000000000002', true);
do $$
begin
  begin
    perform public.dl_world_chat_post('不可发言');
    raise exception 'muted account could still send';
  exception when insufficient_privilege then
    if sqlerrm <> 'chat_muted' then raise; end if;
  end;
  begin
    update public.profiles set title = 'SHOP_PORTRAITS' where id = auth.uid();
    raise exception 'bundle equipped as a title';
  exception when insufficient_privilege then null;
  end;
  update public.profiles set title = 'SHOP_DUANLIAN' where id = auth.uid();
end;
$$;

select set_config('request.jwt.claim.sub', 'ad280000-0000-4000-8000-000000000001', true);
select public.dl_admin_player_update('ad280000-0000-4000-8000-000000000002', 'revoke_item', '活动结束', 'SHOP_DUANLIAN');
select public.dl_admin_player_update('ad280000-0000-4000-8000-000000000002', 'unmute_chat', '处理结束');

select set_config('request.jwt.claim.sub', 'ad280000-0000-4000-8000-000000000002', true);
do $$
begin
  if exists(select 1 from public.profiles where id = auth.uid() and title is not null) then
    raise exception 'revoked title is still equipped';
  end if;
  perform public.dl_world_chat_post('解除后可以发言');
end;
$$;

select set_config('request.jwt.claim.sub', 'ad280000-0000-4000-8000-000000000003', true);
do $$
begin
  if exists(select 1 from public.inventory where uid <> auth.uid()) then raise exception 'other inventory visible'; end if;
  if not exists(select 1 from public.world_chat where message = '解除后可以发言') then
    raise exception 'world chat was not visible across accounts';
  end if;
end;
$$;

rollback;
select 'account inventory, moderation and world chat passed' as verification;
