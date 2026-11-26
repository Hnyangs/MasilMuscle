-- 가입 시 profiles 자동 생성 트리거만 단독 실행용 (여러 번 실행해도 안전, 기존 테이블/데이터는 건드리지 않음)
-- 전제: public.profiles(id, email, name, role, level) 컬럼이 이미 존재해야 합니다.
-- Supabase 대시보드 > SQL Editor에서 실행하세요.

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name, role, level)
  values (
    new.id, lower(new.email),
    coalesce(new.raw_user_meta_data->>'name', ''),
    case when new.raw_user_meta_data->>'role' = 'trainer' then 'trainer' else 'member' end,
    case when new.raw_user_meta_data->>'level' in ('초급','중급','고급') then new.raw_user_meta_data->>'level' else '초급' end
  )
  on conflict (id) do nothing;   -- 이미 프로필이 있으면 건너뜀
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
