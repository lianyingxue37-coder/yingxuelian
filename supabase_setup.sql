-- 《断链》账户系统 · 建表脚本
-- 用法：Supabase 项目 → SQL Editor → New query → 整段粘贴 → Run。可以重复运行。

-- 1. 玩家资料：昵称、头像、称号、战绩、成就
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text unique not null,
  nickname text not null default '无名',
  avatar text not null default 'CH_JIN',
  title text,
  stats jsonb not null default '{}'::jsonb,
  achievements jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_format check (username ~ '^[a-z0-9_]{3,16}$'),
  constraint profiles_nickname_len check (char_length(nickname) between 1 and 12)
);
alter table public.profiles enable row level security;

drop policy if exists "profiles_select_all" on public.profiles;
create policy "profiles_select_all" on public.profiles for select using (true);
drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own" on public.profiles for insert with check (auth.uid() = id);
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- 2. 注册时自动建资料（账号名、昵称、头像来自注册时填写的内容）
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, nickname, avatar)
  values (
    new.id,
    lower(coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1))),
    left(coalesce(nullif(new.raw_user_meta_data ->> 'nickname', ''), new.raw_user_meta_data ->> 'username', '无名'), 12),
    coalesce(new.raw_user_meta_data ->> 'avatar', 'CH_JIN')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- 3. 对战记录（每人只能看、只能写自己的）
create table if not exists public.matches (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  mode text not null,
  my_char text,
  opp_char text,
  opp_id uuid,
  opp_name text,
  result text not null check (result in ('win', 'lose', 'draw')),
  rounds text,
  max_hits int,
  max_lv int,
  stage text,
  created_at timestamptz not null default now()
);
alter table public.matches enable row level security;
drop policy if exists "matches_select_own" on public.matches;
create policy "matches_select_own" on public.matches for select using (auth.uid() = user_id);
drop policy if exists "matches_insert_own" on public.matches;
create policy "matches_insert_own" on public.matches for insert with check (auth.uid() = user_id);
create index if not exists matches_user_time on public.matches (user_id, created_at desc);

-- 4. 检查：能看到两张表就说明建好了
select table_name from information_schema.tables where table_schema = 'public' and table_name in ('profiles', 'matches');
