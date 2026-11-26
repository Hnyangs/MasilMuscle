-- 004: 소셜 로그인(카카오·구글) 첫 가입 처리
-- migration_002 실행 후, Supabase SQL Editor에서 실행하세요. (여러 번 실행해도 안전)
--
-- 소셜 가입은 이름·역할·숙련도를 가입 폼으로 받지 못하므로,
-- 프로필을 onboarded = false 로 만들고 앱의 첫 화면에서 complete_onboarding RPC로 한 번만 입력받는다.

-- 1) 온보딩 여부 (기존 회원은 모두 완료 상태)
alter table public.profiles add column if not exists onboarded boolean not null default true;

-- 2) 가입 트리거: 소셜 메타데이터(full_name, nickname 등)에서도 이름을 가져오고,
--    이메일 가입이 아니면 onboarded = false
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, email, name, role, level, onboarded)
  values (
    new.id, lower(new.email),
    coalesce(nullif(m->>'name', ''), nullif(m->>'full_name', ''), nullif(m->>'nickname', ''),
             nullif(m->>'preferred_username', ''), nullif(m->>'user_name', ''), ''),
    case when m->>'role' = 'trainer' then 'trainer' else 'member' end,
    case when m->>'level' in ('초급','중급','고급') then m->>'level' else '초급' end,
    coalesce(new.raw_app_meta_data->>'provider', 'email') = 'email'
  ) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 3) 본인 수정 보호에 onboarded 추가 (스스로 온보딩을 다시 열어 역할을 바꾸지 못하게)
create or replace function public.guard_profile_update() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.bypass_guard', true), '') <> '1'
     and auth.uid() is not null and auth.uid() = old.id then
    new.role := old.role; new.trainer_id := old.trainer_id; new.notes := old.notes;
    new.curriculum := old.curriculum; new.trainer_code := old.trainer_code; new.email := old.email;
    new.onboarded := old.onboarded;
  end if;
  return new;
end $$;

-- 4) 첫 소셜 가입 시 한 번만: 이름 · 역할 · 숙련도 등록
create or replace function public.complete_onboarding(p_name text, p_role text, p_level text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from profiles where id = auth.uid() and onboarded = false) then
    raise exception '이미 가입 정보가 등록돼 있어요';
  end if;
  if coalesce(trim(p_name), '') = '' or p_role not in ('member','trainer') or p_level not in ('초급','중급','고급') then
    raise exception '이름, 역할, 숙련도를 확인해주세요';
  end if;
  perform set_config('app.bypass_guard', '1', true);
  update profiles set name = trim(p_name), role = p_role, level = p_level, onboarded = true where id = auth.uid();
end $$;
revoke execute on function public.complete_onboarding(text, text, text) from public, anon;
grant execute on function public.complete_onboarding(text, text, text) to authenticated;
