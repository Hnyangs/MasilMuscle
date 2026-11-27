-- 믓 Supabase 스키마. Supabase 대시보드 > SQL Editor에서 한 번 실행하세요.
-- (Authentication > Providers > Email 사용. 이메일 인증을 켜 두면 가입 후 인증 메일 확인이 필요합니다.)

create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  email text,
  name text not null default '',
  role text not null default 'member' check (role in ('member','trainer')),
  level text not null default '초급' check (level in ('초급','중급','고급')),
  trainer_id uuid references public.profiles(id) on delete set null,
  notes text not null default '',
  curriculum text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists profiles_email_idx on public.profiles (email);
create index if not exists profiles_trainer_idx on public.profiles (trainer_id);

create table if not exists public.workout_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  log_date date not null default current_date,
  part text not null,                    -- exercises.body_part 값 (제한 없음; 종목 목록은 supabase/exercises.sql)
  exercise text not null,
  sets jsonb not null default '[]',      -- [{"w": 60, "r": 10}, ...] (w: kg, r: reps)
  feedback text not null default '',
  is_pt boolean not null default false,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists workout_logs_user_idx on public.workout_logs (user_id, log_date desc);

create table if not exists public.pt_schedules (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.profiles(id) on delete cascade,
  trainer_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  pt_date date not null,
  pt_time time not null,
  goal text not null default '',
  status text not null default 'scheduled' check (status in ('scheduled','completed','canceled')),
  created_at timestamptz not null default now()
);
create index if not exists pt_member_idx on public.pt_schedules (member_id, pt_date);

-- 가입 시 auth 메타데이터(name, role, level)로 profiles 자동 생성 (이메일 인증 전에도 동작)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name, role, level)
  values (
    new.id, lower(new.email),
    coalesce(new.raw_user_meta_data->>'name', ''),
    case when new.raw_user_meta_data->>'role' = 'trainer' then 'trainer' else 'member' end,
    case when new.raw_user_meta_data->>'level' in ('초급','중급','고급') then new.raw_user_meta_data->>'level' else '초급' end
  ) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- RLS 정책이 profiles를 다시 조회할 때 재귀되지 않도록 security definer 함수 사용
create or replace function public.is_trainer() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and role = 'trainer') $$;
create or replace function public.my_trainer_id() returns uuid
language sql stable security definer set search_path = public as
$$ select trainer_id from profiles where id = auth.uid() $$;
create or replace function public.is_my_member(uid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = uid and trainer_id = auth.uid()) $$;

alter table public.profiles enable row level security;
alter table public.workout_logs enable row level security;
alter table public.pt_schedules enable row level security;

-- profiles: 본인 / 내 담당 회원 / 내 트레이너 / (트레이너가 이메일로 회원 검색)
create policy profiles_select on public.profiles for select using (
  id = auth.uid() or trainer_id = auth.uid() or id = public.my_trainer_id()
  or (public.is_trainer() and role = 'member'));
create policy profiles_insert on public.profiles for insert with check (id = auth.uid());
-- 트레이너만 회원 프로필 수정 가능(미배정 회원을 내 회원으로 등록, 노트/커리큘럼 작성)
create policy profiles_update on public.profiles for update
  using (public.is_trainer() and role = 'member' and (trainer_id is null or trainer_id = auth.uid()))
  with check (role = 'member' and trainer_id = auth.uid());

-- workout_logs: 본인 기록 또는 내 담당 회원 기록
create policy logs_select on public.workout_logs for select using (user_id = auth.uid() or public.is_my_member(user_id));
create policy logs_insert on public.workout_logs for insert with check (
  (user_id = auth.uid() and is_pt = false) or (public.is_my_member(user_id) and is_pt = true));
create policy logs_delete on public.workout_logs for delete using (user_id = auth.uid() or public.is_my_member(user_id));

-- pt_schedules: 회원은 조회만, 담당 트레이너는 관리
create policy pt_select on public.pt_schedules for select using (member_id = auth.uid() or trainer_id = auth.uid());
create policy pt_insert on public.pt_schedules for insert with check (trainer_id = auth.uid() and public.is_my_member(member_id));
create policy pt_update on public.pt_schedules for update using (trainer_id = auth.uid()) with check (trainer_id = auth.uid() and public.is_my_member(member_id));
create policy pt_delete on public.pt_schedules for delete using (trainer_id = auth.uid());
