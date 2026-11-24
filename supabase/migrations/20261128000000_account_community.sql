-- 立绘权益、玩家管理和全服消息。商城只能预览，新支付仍关闭。
begin;

alter table public.shop_items drop constraint if exists shop_items_kind_check;
alter table public.shop_items add constraint shop_items_kind_check check (kind in ('title', 'bundle'));
alter table public.shop_items alter column price_cny drop not null;
alter table public.inventory add column if not exists admin_granted boolean not null default false;

insert into public.shop_items (id, kind, name, descr, sort)
values ('SHOP_PORTRAITS', 'bundle', '全角色立绘组合包', '七名角色的原创新版立绘', 100)
on conflict (id) do nothing;

create or replace function duanlian_private.check_shop_title()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
begin
  if new.title is distinct from old.title and new.title like 'SHOP\_%'
     and not exists (
       select 1 from public.inventory i join public.shop_items s on s.id = i.item_id
       where i.uid = new.id and i.item_id = new.title and s.kind = 'title'
     )
  then raise exception 'title not owned' using errcode = '42501'; end if;
  return new;
end;
$$;

create table if not exists duanlian_private.world_chat_mutes (
  uid uuid primary key references auth.users(id) on delete cascade
);
alter table duanlian_private.world_chat_mutes enable row level security;
revoke all on duanlian_private.world_chat_mutes from public, anon, authenticated;

create table if not exists public.world_chat (
  id bigint generated always as identity primary key,
  uid uuid not null references auth.users(id) on delete cascade,
  nickname text not null,
  message text not null check (char_length(message) between 1 and 280 and message !~ '[[:cntrl:]]'),
  created_at timestamptz not null default now()
);
alter table public.world_chat enable row level security;
revoke all on public.world_chat from public, anon, authenticated;
grant select on public.world_chat to authenticated;
drop policy if exists world_chat_read on public.world_chat;
create policy world_chat_read on public.world_chat for select to authenticated
  using ((select auth.uid()) is not null and created_at >= now() - interval '7 days');
create index if not exists world_chat_date on public.world_chat (created_at);
drop policy if exists world_chat_realtime_read on realtime.messages;
create policy world_chat_realtime_read on realtime.messages for select to authenticated
  using ((select realtime.topic()) = 'dl-world-chat' and extension = 'broadcast' and (select auth.uid()) is not null);

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime' and not puballtables)
    and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
      and schemaname = 'public' and tablename = 'world_chat')
  then alter publication supabase_realtime add table public.world_chat;
  end if;
end;
$$;

create or replace function duanlian_private.world_account(p_uid uuid)
returns text language plpgsql stable set search_path = pg_catalog as $$
declare v_nickname text;
begin
  select p.nickname into v_nickname
    from public.profiles p join auth.users u on u.id = p.id
    where p.id = p_uid and (u.banned_until is null or u.banned_until <= now());
  if not found then raise exception 'account_required' using errcode = '42501'; end if;
  return v_nickname;
end;
$$;
revoke all on function duanlian_private.world_account(uuid) from public, anon, authenticated;

create or replace function public.dl_world_chat_post(p_message text)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare
  v_uid uuid := auth.uid();
  v_nickname text := duanlian_private.world_account(v_uid);
  v_message text := btrim(regexp_replace(p_message, '[[:space:]]+', ' ', 'g'));
  v_entry public.world_chat%rowtype;
begin
  if p_message is null or octet_length(p_message) > 1120 or char_length(v_message) not between 1 and 280
    or v_message ~ '[[:cntrl:]]'
  then raise exception 'invalid_message' using errcode = '22023'; end if;
  if exists (select 1 from duanlian_private.world_chat_mutes where uid = v_uid)
  then raise exception 'chat_muted' using errcode = '42501'; end if;
  perform duanlian_private.check_limit(v_uid, 'world_chat_post', 8);
  insert into public.world_chat (uid, nickname, message)
    values (v_uid, v_nickname, v_message) returning * into v_entry;
  delete from public.world_chat where created_at < now() - interval '7 days';
  return to_jsonb(v_entry);
end;
$$;

create or replace function public.dl_world_voice_authorize()
returns void language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform duanlian_private.world_account(auth.uid());
  perform duanlian_private.check_limit(auth.uid(), 'world_voice', 6);
end;
$$;

alter table duanlian_private.admin_audit drop constraint if exists admin_audit_action_check;
alter table duanlian_private.admin_audit add constraint admin_audit_action_check
  check (action in ('ban', 'unban', 'close_room', 'edit_profile', 'grant_item', 'revoke_item', 'mute_chat', 'unmute_chat'));
alter table duanlian_private.admin_audit add column if not exists detail jsonb;

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
      select id, actor_name, action, target_name, reason, detail, created_at,
        case when status = 'pending' and created_at <= now() - interval '2 minutes' then 'uncertain' else status end as status
      from duanlian_private.admin_audit
      order by created_at desc, id desc offset p_offset limit 21
    ) a
  );
end;
$$;

create or replace function duanlian_private.item_has_order(p_uid uuid, p_item text)
returns boolean language sql stable set search_path = pg_catalog as $$
  select exists (select 1 from public.shop_orders where uid = p_uid and item_id = p_item and status = 'granted')
      or exists (select 1 from public.coin_unlocks where uid = p_uid and item_id = p_item and status <> 'FAILED');
$$;
revoke all on function duanlian_private.item_has_order(uuid, text) from public, anon, authenticated;

create or replace function public.dl_admin_player(p_target uuid)
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
declare v_profile jsonb;
begin
  perform duanlian_private.admin_require(auth.uid());
  select jsonb_build_object('id', p.id, 'username', p.username, 'nickname', p.nickname, 'avatar', p.avatar,
    'title', p.title, 'rating', p.rating, 'roles_locked',
    exists(select 1 from duanlian_private.admin_members a where a.uid = p.id), 'muted',
    exists(select 1 from duanlian_private.world_chat_mutes m where m.uid = p.id))
    into v_profile from public.profiles p where p.id = p_target;
  if not found then raise exception 'account_not_found'; end if;

  return v_profile || jsonb_build_object(
    'inventory', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'kind', s.kind,
      'admin_granted', i.admin_granted and not duanlian_private.item_has_order(i.uid, i.item_id),
      'granted_at', i.granted_at) order by s.sort, s.id), '[]'::jsonb)
      from public.inventory i join public.shop_items s on s.id = i.item_id where i.uid = p_target),
    'catalog', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'kind', s.kind)
      order by s.sort, s.id), '[]'::jsonb) from public.shop_items s where s.active));
end;
$$;

create or replace function public.dl_admin_player_update(
  p_target uuid, p_action text, p_reason text, p_value text default null, p_avatar text default null
)
returns void language plpgsql security definer set search_path = pg_catalog as $$
declare
  v_actor uuid := auth.uid();
  v_actor_name text := duanlian_private.admin_require(v_actor);
  v_target_name text;
  v_value text := btrim(p_value);
  v_detail jsonb;
begin
  if coalesce(char_length(btrim(p_reason)), 0) not between 1 and 240 then
    raise exception 'invalid_reason' using errcode = '22023';
  end if;
  if exists (select 1 from duanlian_private.admin_members where uid = p_target) then
    raise exception 'protected_account' using errcode = '42501';
  end if;
  select username into v_target_name from public.profiles where id = p_target for update;
  if not found then raise exception 'account_not_found'; end if;
  perform duanlian_private.check_limit(v_actor, 'dl_admin_player_update', 30);

  case p_action
  when 'edit_profile' then
    if v_value is null or char_length(v_value) not between 1 and 12 or v_value ~ '[[:cntrl:]]'
      or p_avatar is null or p_avatar !~ '^CH_(JIN|LAN|YUE|YING|LING|SHUANG|LEI)$'
    then raise exception 'invalid_profile' using errcode = '22023'; end if;
    update public.profiles set nickname = v_value, avatar = p_avatar where id = p_target
      and (nickname is distinct from v_value or avatar is distinct from p_avatar);
    if not found then return; end if;
    v_detail := jsonb_build_object('nickname', v_value, 'avatar', p_avatar);
  when 'grant_item' then
    if not exists (select 1 from public.shop_items where id = v_value and active) then
      raise exception 'item_not_found';
    end if;
    insert into public.inventory (uid, item_id, admin_granted) values (p_target, v_value, true) on conflict do nothing;
    if not found then return; end if;
    v_detail := jsonb_build_object('item_id', v_value);
  when 'revoke_item' then
    delete from public.inventory where uid = p_target and item_id = v_value and admin_granted
      and not duanlian_private.item_has_order(p_target, v_value);
    if not found then
      if exists (select 1 from public.inventory where uid = p_target and item_id = v_value)
      then raise exception 'item_not_admin_granted'; end if;
      return;
    end if;
    update public.profiles set title = null where id = p_target and title = v_value;
    v_detail := jsonb_build_object('item_id', v_value);
  when 'mute_chat' then
    insert into duanlian_private.world_chat_mutes (uid) values (p_target) on conflict do nothing;
    if not found then return; end if;
  when 'unmute_chat' then
    delete from duanlian_private.world_chat_mutes where uid = p_target;
    if not found then return; end if;
  else raise exception 'invalid_account_action' using errcode = '22023';
  end case;

  insert into duanlian_private.admin_audit (actor, actor_name, action, target, target_name, reason, status, detail)
    values (v_actor, v_actor_name, p_action, p_target, v_target_name, btrim(p_reason), 'done', v_detail);
end;
$$;

revoke all on function public.dl_world_chat_post(text), public.dl_world_voice_authorize(),
  public.dl_admin_player(uuid), public.dl_admin_player_update(uuid, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.dl_world_chat_post(text), public.dl_world_voice_authorize(),
  public.dl_admin_player(uuid), public.dl_admin_player_update(uuid, text, text, text, text)
  to authenticated;

notify pgrst, 'reload schema';
commit;
