-- 005: 트레이너 도구
--   · 회원 고유코드 (동명이인 구분)       · 앱을 쓰지 않는 회원(이메일 없음)을 트레이너가 직접 등록
--   · 이름/코드/이메일로 회원 검색        · 트레이너 프로필(센터명·경력·전문 분야·소개)
--   · 트레이너 노트를 회원에게 비공개로 (member_notes 테이블로 이동)
-- migration_004 실행 후, Supabase SQL Editor에서 실행하세요. (여러 번 실행해도 안전)

-- 1) 트레이너 프로필
alter table public.profiles add column if not exists center_name text not null default '';
alter table public.profiles add column if not exists career text not null default '';
alter table public.profiles add column if not exists specialty text not null default '';
alter table public.profiles add column if not exists bio text not null default '';

-- 2) 회원 고유코드 + 앱 미사용(관리형) 회원
alter table public.profiles add column if not exists member_code text;
alter table public.profiles add column if not exists is_managed boolean not null default false;
create unique index if not exists profiles_member_code_key on public.profiles (member_code) where member_code is not null;
-- 관리형 회원은 로그인 계정(auth.users)이 없으므로 profiles.id 의 auth.users 외래키를 푼다
alter table public.profiles drop constraint if exists profiles_id_fkey;
alter table public.profiles alter column id set default gen_random_uuid();

create or replace function public.gen_member_code() returns text
language plpgsql as $$
declare c text;
begin
  loop
    c := 'M' || lpad(floor(random() * 1000000)::int::text, 6, '0');
    exit when not exists (select 1 from public.profiles where member_code = c);
  end loop;
  return c;
end $$;

create or replace function public.set_member_code() returns trigger
language plpgsql as $$
begin
  if new.role = 'member' and new.member_code is null then new.member_code := public.gen_member_code(); end if;
  return new;
end $$;
drop trigger if exists profiles_member_code on public.profiles;
create trigger profiles_member_code before insert or update of role on public.profiles
  for each row execute function public.set_member_code();

do $$ declare r record; begin
  for r in select id from public.profiles where role = 'member' and member_code is null loop
    update public.profiles set member_code = public.gen_member_code() where id = r.id;
  end loop;
end $$;

-- 3) 본인 수정 보호에 member_code, is_managed 추가 (004의 onboarded 포함)
create or replace function public.guard_profile_update() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.bypass_guard', true), '') <> '1'
     and auth.uid() is not null and auth.uid() = old.id then
    new.role := old.role; new.trainer_id := old.trainer_id; new.notes := old.notes;
    new.curriculum := old.curriculum; new.trainer_code := old.trainer_code; new.email := old.email;
    new.onboarded := old.onboarded; new.member_code := old.member_code; new.is_managed := old.is_managed;
  end if;
  return new;
end $$;

-- 4) 트레이너가 앱 미사용 회원을 직접 등록 (이메일 없이, 고유코드 자동 부여)
create or replace function public.create_managed_member(p_name text, p_level text default '초급')
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare r public.profiles;
begin
  if not public.is_trainer() then raise exception '트레이너만 회원을 등록할 수 있어요'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception '이름을 입력해주세요'; end if;
  insert into profiles (id, email, name, role, level, trainer_id, is_managed, onboarded)
  values (gen_random_uuid(), null, trim(p_name), 'member',
          case when p_level in ('초급','중급','고급') then p_level else '초급' end, auth.uid(), true, true)
  returning * into r;
  return r;
end $$;

-- 5) 회원 검색: 이름(부분 일치) · 회원코드 · 이메일. 이메일은 가려서 돌려준다.
--    다른 트레이너의 관리형 회원은 보이지 않는다.
create or replace function public.search_members(q text)
returns table (id uuid, name text, member_code text, level text, email_hint text, is_managed boolean, trainer_state text)
language sql stable security definer set search_path = public as $$
  select p.id, p.name, p.member_code, p.level,
         case when coalesce(p.email, '') = '' or p.email like '%@naver.invalid' then null
              else regexp_replace(p.email, '^(.{2})[^@]*', '\1***') end,
         p.is_managed,
         case when p.trainer_id = auth.uid() then 'mine' when p.trainer_id is null then 'none' else 'other' end
  from profiles p
  where public.is_trainer() and p.role = 'member' and length(trim(q)) >= 1
    and not (p.is_managed and p.trainer_id is distinct from auth.uid())
    and (p.name ilike '%' || trim(q) || '%' or upper(p.member_code) = upper(trim(q)) or lower(p.email) = lower(trim(q)))
  order by (p.trainer_id = auth.uid()) desc nulls last, p.name
  limit 20
$$;

revoke execute on function public.create_managed_member(text, text) from public, anon;
revoke execute on function public.search_members(text) from public, anon;
grant execute on function public.create_managed_member(text, text) to authenticated;
grant execute on function public.search_members(text) to authenticated;

-- 6) 트레이너 노트 비공개: 회원 본인은 읽지 못하는 별도 테이블 (트레이너별로 따로 보관)
create table if not exists public.member_notes (
  member_id uuid not null references public.profiles(id) on delete cascade,
  trainer_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  notes text not null default '',
  curriculum text not null default '',
  updated_at timestamptz not null default now(),
  primary key (member_id, trainer_id)
);
alter table public.member_notes enable row level security;
drop policy if exists member_notes_all on public.member_notes;
create policy member_notes_all on public.member_notes for all
  using (trainer_id = auth.uid() and public.is_my_member(member_id))
  with check (trainer_id = auth.uid() and public.is_my_member(member_id));

-- 기존 profiles 의 노트를 옮기고 회원이 읽을 수 있던 자리는 비운다
insert into public.member_notes (member_id, trainer_id, notes, curriculum)
select id, trainer_id, notes, curriculum from public.profiles
where trainer_id is not null and (notes <> '' or curriculum <> '')
on conflict (member_id, trainer_id) do nothing;
update public.profiles set notes = '', curriculum = '' where notes <> '' or curriculum <> '';
