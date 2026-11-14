-- 오르락내리락 그룹 기능용 테이블
-- Supabase 대시보드 → SQL Editor → 새 쿼리에 전부 붙여넣고 Run

-- 그룹: 6자리 초대 코드가 곧 그룹 ID
create table if not exists public.groups (
  code       text primary key check (code ~ '^[A-Z0-9]{6}$'),
  name       text not null check (char_length(name) between 1 and 20),
  owner      uuid not null default auth.uid(),
  created_at timestamptz not null default now()
);

-- 멤버: 그룹마다 내 기록 한 줄 (이번 시즌 자산, 플렉스 점수, 캐릭터·집·차 꾸미기)
create table if not exists public.members (
  group_code text not null references public.groups(code) on delete cascade,
  uid        uuid not null default auth.uid(),
  nick       text not null check (char_length(nick) between 1 and 12),
  season     int  not null,
  total      bigint not null default 0,
  flex       bigint not null default 0,
  profile    jsonb  not null default '{}'::jsonb check (octet_length(profile::text) < 8000),
  updated_at timestamptz not null default now(),
  primary key (group_code, uid)
);
create index if not exists members_group_idx on public.members(group_code);

-- 내가 그 그룹 멤버인지 (보안 규칙에서 사용)
create or replace function public.is_member(g text) returns boolean
language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.members where group_code = g and uid = auth.uid());
$$;

alter table public.groups  enable row level security;
alter table public.members enable row level security;

-- 그룹 이름은 초대 코드를 아는 사람이면 볼 수 있음 (참가 전 확인용)
drop policy if exists groups_read   on public.groups;
drop policy if exists groups_create on public.groups;
drop policy if exists groups_delete on public.groups;
create policy groups_read   on public.groups for select to authenticated using (true);
create policy groups_create on public.groups for insert to authenticated with check (owner = auth.uid());
create policy groups_delete on public.groups for delete to authenticated using (owner = auth.uid());

-- 멤버 기록은 같은 그룹 사람만 볼 수 있고, 내 줄만 쓰고 지울 수 있음
drop policy if exists members_read   on public.members;
drop policy if exists members_join   on public.members;
drop policy if exists members_update on public.members;
drop policy if exists members_leave  on public.members;
create policy members_read   on public.members for select to authenticated using (public.is_member(group_code));
create policy members_join   on public.members for insert to authenticated with check (uid = auth.uid());
create policy members_update on public.members for update to authenticated using (uid = auth.uid()) with check (uid = auth.uid());
create policy members_leave  on public.members for delete to authenticated using (uid = auth.uid());

-- 그룹당 최대 50명
create or replace function public.check_group_size() returns trigger
language plpgsql as $$
begin
  if (select count(*) from public.members where group_code = new.group_code) >= 50 then
    raise exception 'group full';
  end if;
  return new;
end $$;
drop trigger if exists group_size on public.members;
create trigger group_size before insert on public.members
  for each row execute function public.check_group_size();
