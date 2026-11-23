-- 商城断言：在测试项目或本地 Postgres 跑，结束时回滚。
begin;

insert into auth.users (id, email, raw_user_meta_data) values
  ('5b00000a-0000-4000-8000-000000000001', 'shoptest_a@players.duanlian.game', '{"username":"shoptest_a"}'),
  ('5b00000b-0000-4000-8000-000000000002', 'shoptest_b@players.duanlian.game', '{"username":"shoptest_b"}');
update public.shop_items set afdian_plan_id = 'plan_test_1' where id = 'SHOP_DUANLIAN';
update public.shop_items set afdian_plan_id = 'sku_test_2' where id = 'SHOP_ZHONGYAN';

do $$
declare r jsonb;
begin
  -- 玩家不能直接写库存、订单，也不能调用发货函数
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '5b00000a-0000-4000-8000-000000000001', true);
  begin insert into public.inventory (uid, item_id) values (auth.uid(), 'SHOP_DUANLIAN'); raise exception 'player can write inventory';
  exception when insufficient_privilege then null; end;
  begin perform public.shop_grant('1000000001', 'plan_test_1', '', 6, '', auth.uid(), 'claim'); raise exception 'player can call shop_grant';
  exception when insufficient_privilege then null; end;
  -- 没买的商城称号挂不上
  begin update public.profiles set title = 'SHOP_DUANLIAN' where id = auth.uid(); raise exception 'unowned shop title allowed';
  exception when insufficient_privilege then null; end;
  if (select count(*) from public.shop_items) < 4 then raise exception 'catalog not readable'; end if;
  reset role;

  -- 填订单号领取
  set local role service_role;
  r := public.shop_grant('1000000001', 'plan_test_1', '', 6, '', '5b00000a-0000-4000-8000-000000000001', 'claim');
  if not (r->>'ok')::boolean or r->>'item' <> 'SHOP_DUANLIAN' then raise exception 'claim failed: %', r; end if;
  -- 同一订单再领：本人 already，别人 taken，不会多发
  r := public.shop_grant('1000000001', 'plan_test_1', '', 6, '', '5b00000a-0000-4000-8000-000000000001', 'claim');
  if r->>'status' <> 'already' then raise exception 'repeat claim: %', r; end if;
  r := public.shop_grant('1000000001', 'plan_test_1', '', 6, '', '5b00000b-0000-4000-8000-000000000002', 'claim');
  if r->>'status' <> 'taken' or (r->>'ok')::boolean then raise exception 'stolen claim: %', r; end if;
  -- webhook：留言里有领取码就自动发货（按 sku 匹配商品）
  r := public.shop_grant('1000000002', '', 'sku_test_2', 12, '谢谢 dl5b00000a 加油', null, 'webhook');
  if not (r->>'ok')::boolean or r->>'item' <> 'SHOP_ZHONGYAN' then raise exception 'webhook grant failed: %', r; end if;
  -- webhook：没有领取码 → 记为待领取，之后本人填订单号还能领
  r := public.shop_grant('1000000003', 'plan_test_1', '', 6, '', null, 'webhook');
  if r->>'status' <> 'unclaimed' then raise exception 'unclaimed: %', r; end if;
  r := public.shop_grant('1000000003', 'plan_test_1', '', 6, '', '5b00000b-0000-4000-8000-000000000002', 'claim');
  if not (r->>'ok')::boolean then raise exception 'claim after webhook: %', r; end if;
  -- 不认识的方案不发货
  r := public.shop_grant('1000000004', 'plan_unknown', '', 1, 'DL5B00000A', null, 'webhook');
  if r->>'status' <> 'unknown_plan' then raise exception 'unknown plan: %', r; end if;
  r := public.shop_grant('abc', 'plan_test_1', '', 6, '', null, 'webhook');
  if r->>'status' <> 'bad_trade' then raise exception 'bad trade: %', r; end if;
  for i in 1..6 loop perform public.shop_claim_gate('5b00000a-0000-4000-8000-000000000001'); end loop;
  begin perform public.shop_claim_gate('5b00000a-0000-4000-8000-000000000001'); raise exception 'claim rate limit missing';
  exception when others then if sqlerrm <> 'rate limit exceeded' then raise; end if; end;
  reset role;

  if (select count(*) from public.inventory where uid = '5b00000a-0000-4000-8000-000000000001') <> 2 then raise exception 'inventory A wrong'; end if;
  if (select count(*) from public.inventory where uid = '5b00000b-0000-4000-8000-000000000002') <> 1 then raise exception 'inventory B wrong'; end if;

  -- 买了就能挂；只能看到自己的库存和订单
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '5b00000a-0000-4000-8000-000000000001', true);
  update public.profiles set title = 'SHOP_ZHONGYAN' where id = auth.uid();
  update public.profiles set title = 'ACH_CPU2' where id = auth.uid();
  if (select count(*) from public.inventory) <> 2 then raise exception 'inventory visibility'; end if;
  if exists (select 1 from public.shop_orders where uid <> auth.uid()) then raise exception 'orders leak'; end if;
  reset role;
end;
$$;

select 'shop assertions passed' as verification;
rollback;
