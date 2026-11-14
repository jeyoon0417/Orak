-- 오르락내리락 전체 랭킹 + 조작 걸러내기
-- Supabase 대시보드 → SQL Editor → New query 에 전부 붙여넣고 Run
-- (그룹용 supabase-groups.sql 은 이미 실행돼 있어야 해. 이건 추가로 한 번만 실행하면 됨)

-- ---------- 1. 테이블 ----------
-- 시즌마다 유저 한 줄. status: 0 공개 / 1 기록이 너무 높아 확인 대기 / 2 운영자 승인 / 3 신고 누적으로 확인 대기
create table if not exists public.world (
  season     int    not null,
  uid        uuid   not null default auth.uid(),
  nick       text   not null check (char_length(nick) between 1 and 12),
  total      bigint not null default 0,
  flex       bigint not null default 0,
  profile    jsonb  not null default '{}'::jsonb check (octet_length(profile::text) < 8000),
  status     smallint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (season, uid)
);
create index if not exists world_total_idx on public.world (season, total desc);
create index if not exists world_flex_idx  on public.world (season, flex desc);

-- 정지된 유저 (운영자가 Table Editor 에서 uid 를 직접 추가)
create table if not exists public.banned (
  uid        uuid primary key,
  reason     text,
  created_at timestamptz not null default now()
);

-- 신고 (한 사람이 같은 유저를 시즌당 한 번만)
create table if not exists public.reports (
  season     int  not null,
  target     uuid not null,
  reporter   uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (season, target, reporter)
);

create or replace function public.is_banned(u uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select exists(select 1 from public.banned where uid = u);
$$;

-- ---------- 2. 시즌 계산 (게임과 똑같이: 한국시간 월요일 0시 시작, 7일) ----------
create or replace function public.orak_season() returns table(id int, elapsed double precision)
language sql stable as $$
  with d as (
    select floor((extract(epoch from now()) * 1000 + 9 * 3600000) / 86400000)::bigint as day,
           extract(epoch from now()) as nowsec
  ), m as (
    select day - ((day + 3) % 7) as mon, nowsec from d
  )
  select floor(mon / 7.0)::int,
         nowsec - (mon * 86400 - 9 * 3600)
  from m;
$$;

-- ---------- 3. 시간당 최대 상승 배수 ----------
-- 시즌 14개를 시뮬레이션해서, 그 시간 안에 한 종목을 바닥에서 사서 꼭대기에 팔았을 때의 최대 배수를 구하고 1.5배 여유를 줌
create or replace function public.orak_best(sec double precision) returns double precision
language plpgsql immutable as $$
declare
  xs double precision[] := array[0,30,60,120,300,600,1800,3600,10800,21600,43200,86400,259200,604800];
  ys double precision[] := array[1,3.6,4.4,5,6.5,7.7,16,29,145,380,700,2500,14000,50000];
  i int;
begin
  if sec <= 0 then return 1; end if;
  if sec >= xs[14] then return ys[14]; end if;
  for i in 2..14 loop
    if sec <= xs[i] then
      return exp(ln(ys[i-1]) + (ln(ys[i]) - ln(ys[i-1])) * (sec - xs[i-1]) / (xs[i] - xs[i-1]));
    end if;
  end loop;
  return ys[14];
end $$;

-- ---------- 4. 저장할 때마다 검사하는 장치 ----------
create or replace function public.world_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  s record;
  dt double precision;
  soft double precision;
  hard double precision;
  START constant bigint := 5000000;   -- 시작 자금
  LOAN  constant bigint := 5000000;   -- 최대 대출
begin
  -- 운영자가 대시보드에서 고치는 건 통과 (로그인 유저가 아님)
  if auth.uid() is null then return new; end if;
  -- 신고 누적 처리처럼 서버 안에서 바꾸는 건 통과
  if pg_trigger_depth() > 1 then return new; end if;

  if exists (select 1 from banned where uid = auth.uid()) then
    raise exception 'banned';
  end if;

  select * into s from orak_season();
  if new.season <> s.id then raise exception 'season'; end if;

  -- 자산 범위
  if new.total < -LOAN then raise exception 'range'; end if;
  hard := (START + LOAN) * orak_best(s.elapsed) * 3;     -- 이걸 넘으면 아예 저장 거부
  soft := (START + LOAN) * orak_best(s.elapsed);         -- 이걸 넘으면 저장은 하되 숨기고 확인 대기
  if new.total > hard then raise exception 'range'; end if;

  -- 플렉스는 상점 물건 전부 산 값(약 108억)을 넘을 수 없음. 아이템 추가하면 이 숫자도 올려줘
  if new.flex < 0 or new.flex > 20000000000 then raise exception 'flex'; end if;

  if tg_op = 'UPDATE' then
    -- 너무 자주 저장 금지
    dt := extract(epoch from now() - old.updated_at);
    if dt < 15 then raise exception 'fast'; end if;
    -- 지난 저장보다 말이 안 되게 늘었으면 거부 (대출 최대치까지 끌어 썼다고 쳐도)
    if new.total > (greatest(old.total, 0) + LOAN) * orak_best(dt) * 1.5 then
      raise exception 'jump';
    end if;
    -- 상태는 클라이언트가 못 바꿈
    new.status := old.status;
    if new.status = 0 and new.total > soft then new.status := 1; end if;
  else
    new.status := case when new.total > soft then 1 else 0 end;
  end if;

  new.uid := auth.uid();
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists world_guard on public.world;
create trigger world_guard before insert or update on public.world
  for each row execute function public.world_guard();

-- 신고가 5명 쌓이면 확인 대기로 숨김 (운영자 승인(2)된 사람은 제외)
create or replace function public.report_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.reporter = new.target then raise exception 'self'; end if;
  if (select count(*) from reports where season = new.season and target = new.target) >= 5 then
    update world set status = 3 where season = new.season and uid = new.target and status = 0;
  end if;
  return new;
end $$;

drop trigger if exists report_guard on public.reports;
create trigger report_guard after insert on public.reports
  for each row execute function public.report_guard();

-- ---------- 5. 보안 규칙 (RLS) ----------
alter table public.world   enable row level security;
alter table public.banned  enable row level security;
alter table public.reports enable row level security;

drop policy if exists world_read   on public.world;
drop policy if exists world_insert on public.world;
drop policy if exists world_update on public.world;
-- 공개(0)·승인(2)된 기록은 누구나, 내 기록은 상태와 상관없이 볼 수 있음. 정지된 유저는 안 보임
create policy world_read on public.world for select to authenticated
  using ((status in (0, 2) and not public.is_banned(world.uid)) or uid = auth.uid());
create policy world_insert on public.world for insert to authenticated with check (uid = auth.uid());
create policy world_update on public.world for update to authenticated using (uid = auth.uid()) with check (uid = auth.uid());

-- 신고는 쓰기만 가능 (누가 신고했는지는 안 보임)
drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports for insert to authenticated with check (reporter = auth.uid());

-- banned 는 정책이 없으므로 앱에서는 읽기·쓰기 불가 (대시보드에서만 관리)
