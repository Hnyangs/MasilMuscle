-- 002: 마이페이지(내 정보) · 강사 코드 연결 · 인바디 · PT 신청 · 운동 노트
-- schema.sql / exercises.sql 실행 후, Supabase SQL Editor에서 전체를 한 번 실행하세요. (여러 번 실행해도 안전)

-- 1) 내 정보 컬럼 + 트레이너 코드
alter table public.profiles add column if not exists goal text not null default '';
alter table public.profiles add column if not exists height_cm numeric;
alter table public.profiles add column if not exists birth_date date;
alter table public.profiles add column if not exists start_weight numeric;
alter table public.profiles add column if not exists gender text not null default '';
alter table public.profiles add column if not exists trainer_code text;
create unique index if not exists profiles_trainer_code_key on public.profiles (trainer_code) where trainer_code is not null;

-- 2) 운동 기록 노트(트레이너 수업 메모 / 개인 메모)
alter table public.workout_logs add column if not exists note text not null default '';

-- 3) PT 신청 상태(requested) 추가
alter table public.pt_schedules drop constraint if exists pt_schedules_status_check;
alter table public.pt_schedules add constraint pt_schedules_status_check
  check (status in ('requested','scheduled','completed','canceled'));

-- 4) 인바디 기록
create table if not exists public.inbody_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  measured_on date not null default current_date,
  weight numeric,      -- 체중 kg
  muscle numeric,      -- 골격근량 kg
  fat_pct numeric,     -- 체지방률 %
  note text not null default '',
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists inbody_user_idx on public.inbody_records (user_id, measured_on desc);
alter table public.inbody_records enable row level security;
drop policy if exists inbody_select on public.inbody_records;
drop policy if exists inbody_insert on public.inbody_records;
drop policy if exists inbody_delete on public.inbody_records;
create policy inbody_select on public.inbody_records for select using (user_id = auth.uid() or public.is_my_member(user_id));
create policy inbody_insert on public.inbody_records for insert with check (user_id = auth.uid() or public.is_my_member(user_id));
create policy inbody_delete on public.inbody_records for delete using (user_id = auth.uid() or public.is_my_member(user_id));

-- 5) 본인 프로필 수정 허용 + 민감 컬럼 보호
--    본인이 직접 바꿀 수 있는 건 이름·숙련도·목표·키·생년월일·시작체중·성별뿐.
--    역할/담당 트레이너/노트/커리큘럼/코드는 아래 트리거가 원래 값으로 되돌림 (강사 연결은 link_trainer RPC로만)
create or replace function public.guard_profile_update() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.bypass_guard', true), '') <> '1'
     and auth.uid() is not null and auth.uid() = old.id then
    new.role := old.role; new.trainer_id := old.trainer_id; new.notes := old.notes;
    new.curriculum := old.curriculum; new.trainer_code := old.trainer_code; new.email := old.email;
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.guard_profile_update();

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- 6) 트레이너 코드 발급(4자리) / 회원의 강사 연결·해제
create or replace function public.my_trainer_code() returns text
language plpgsql security definer set search_path = public as $$
declare c text; tries int := 0;
begin
  if not public.is_trainer() then return null; end if;
  select trainer_code into c from profiles where id = auth.uid();
  if c is not null then return c; end if;
  perform set_config('app.bypass_guard', '1', true);
  loop
    c := lpad(floor(random() * 10000)::int::text, 4, '0');
    begin
      update profiles set trainer_code = c where id = auth.uid();
      return c;
    exception when unique_violation then
      tries := tries + 1; if tries > 50 then raise; end if;
    end;
  end loop;
end $$;

create or replace function public.link_trainer(code text) returns text
language plpgsql security definer set search_path = public as $$
declare t_id uuid; t_name text;
begin
  if not exists (select 1 from profiles where id = auth.uid() and role = 'member') then
    raise exception '회원 계정만 강사를 연결할 수 있어요';
  end if;
  select id, name into t_id, t_name from profiles where role = 'trainer' and trainer_code = trim(code);
  if t_id is null then raise exception '일치하는 강사 코드가 없어요'; end if;
  perform set_config('app.bypass_guard', '1', true);
  update profiles set trainer_id = t_id where id = auth.uid();
  return t_name;
end $$;

create or replace function public.unlink_trainer() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.bypass_guard', '1', true);
  update profiles set trainer_id = null where id = auth.uid() and role = 'member';
end $$;

revoke execute on function public.my_trainer_code() from public, anon;
revoke execute on function public.link_trainer(text) from public, anon;
revoke execute on function public.unlink_trainer() from public, anon;
grant execute on function public.my_trainer_code() to authenticated;
grant execute on function public.link_trainer(text) to authenticated;
grant execute on function public.unlink_trainer() to authenticated;

-- 7) 회원의 PT 신청 / 신청 취소
drop policy if exists pt_member_request on public.pt_schedules;
create policy pt_member_request on public.pt_schedules for insert
  with check (member_id = auth.uid() and status = 'requested' and trainer_id = public.my_trainer_id());
drop policy if exists pt_member_cancel on public.pt_schedules;
create policy pt_member_cancel on public.pt_schedules for update
  using (member_id = auth.uid() and status = 'requested')
  with check (member_id = auth.uid() and status = 'canceled');
