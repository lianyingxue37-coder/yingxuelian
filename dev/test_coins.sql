-- 断链币（v3.5）数据库函数测试：psql -v ON_ERROR_STOP=1 -f dev/test_coins.sql（整段回滚，不留数据）
begin;
insert into auth.users (id, email, raw_user_meta_data) values
  ('5c00000a-0000-0000-0000-000000000001', 'cointest_a@players.duanlian.game', '{"username":"cointest_a"}');
do $$
declare r jsonb; k text; s text; u uuid := '5c00000a-0000-0000-0000-000000000001';
begin
  assert (select price_coins from public.shop_items where id = 'SHOP_DUANLIAN') = 60, 'price seeded';
  r := public.shop_unlock_begin(u, 'SHOP_NOPE'); assert r->>'action' = 'bad_item', 'bad item';
  r := public.shop_unlock_begin(u, 'SHOP_DUANLIAN'); assert r->>'action' = 'new' and (r->>'price')::int = 60, 'first new';
  k := r->>'idem_key'; assert k = 'unlock-' || u || '-SHOP_DUANLIAN-1', 'key format';
  r := public.shop_unlock_begin(u, 'SHOP_DUANLIAN'); assert r->>'action' = 'resume' and r->>'idem_key' = k, 'in-flight resumes same key';
  s := public.shop_unlock_settle(k, 'UNKNOWN', ''); assert s = 'UNKNOWN';
  r := public.shop_unlock_begin(u, 'SHOP_DUANLIAN'); assert r->>'action' = 'resume' and r->>'idem_key' = k, 'unknown still resumes';
  s := public.shop_unlock_settle(k, 'FAILED', 'NOW_PAY_QUOTA_INSUFFICIENT'); assert s = 'FAILED';
  s := public.shop_unlock_settle(k, 'SUCCEEDED', ''); assert s = 'FAILED', 'terminal state sticks';
  assert not exists (select 1 from public.inventory where uid = u), 'failed grants nothing';
  r := public.shop_unlock_begin(u, 'SHOP_DUANLIAN'); assert r->>'action' = 'new' and r->>'idem_key' like '%-2', 'after failure new attempt';
  s := public.shop_unlock_settle(r->>'idem_key', 'SUCCEEDED', ''); assert s = 'SUCCEEDED';
  assert exists (select 1 from public.inventory where uid = u and item_id = 'SHOP_DUANLIAN'), 'granted';
  r := public.shop_unlock_begin(u, 'SHOP_DUANLIAN'); assert r->>'action' = 'owned', 'owned';
  assert public.shop_unlock_settle('unlock-nope', 'SUCCEEDED', '') = 'missing', 'unknown key';
  perform public.shop_buy_begin(u, 'buy-5c00000a-abc123', 's60');
  perform public.shop_buy_status('buy-5c00000a-abc123', 'READY');
  assert (select status from public.coin_purchases where idem_key = 'buy-5c00000a-abc123') = 'READY';
  perform public.shop_coins_gate(u);
end $$;
-- 权限：普通登录用户不能直接调这些函数，也写不了表
set local role authenticated;
do $$ begin
  begin perform public.shop_unlock_begin('5c00000a-0000-0000-0000-000000000001', 'SHOP_PATRON'); raise exception 'should fail'; exception when insufficient_privilege then null; end;
  begin perform public.shop_unlock_settle('x', 'SUCCEEDED', ''); raise exception 'should fail'; exception when insufficient_privilege then null; end;
  begin insert into public.coin_unlocks (idem_key, uid, item_id, attempt, price) values ('unlock-5c00000a-0000-0000-0000-000000000001-SHOP_PATRON-9', '5c00000a-0000-0000-0000-000000000001', 'SHOP_PATRON', 9, 1); raise exception 'should fail'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'coins tests passed' as result;
rollback;
