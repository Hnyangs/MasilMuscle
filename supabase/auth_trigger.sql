-- 가입 시 profiles 자동 생성 트리거만 단독 실행용 (여러 번 실행해도 안전, 기존 테이블/데이터는 건드리지 않음)
-- 최신 버전(migration_004·007 반영): 소셜 가입(이메일이 아닌 provider)은 onboarded = false 로 만들어
-- 첫 로그인 때 역할(회원/트레이너)을 묻고, 가입 폼에서 동의한 약관을 기록한다.
-- 전제: migration_002~007 을 실행해 profiles 에 onboarded, terms_agreed_at, under14, guardian_agreed 컬럼이 있어야 합니다.
-- Supabase 대시보드 > SQL Editor에서 실행하세요.

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, email, name, role, level, onboarded, terms_agreed_at, under14, guardian_agreed)
  values (
    new.id, lower(new.email),
    coalesce(nullif(m->>'name', ''), nullif(m->>'full_name', ''), nullif(m->>'nickname', ''),
             nullif(m->>'preferred_username', ''), nullif(m->>'user_name', ''), ''),
    case when m->>'role' = 'trainer' then 'trainer' else 'member' end,
    case when m->>'level' in ('초급','중급','고급') then m->>'level' else '초급' end,
    coalesce(new.raw_app_meta_data->>'provider', 'email') = 'email',
    case when m->>'terms_agreed' = 'true' then now() end,
    coalesce(m->>'under14', '') = 'true',
    coalesce(m->>'guardian_agreed', '') = 'true'
  )
  on conflict (id) do nothing;   -- 이미 프로필이 있으면 건너뜀
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
