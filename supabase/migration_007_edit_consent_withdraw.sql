-- 007: 운동 기록 수정 · 약관 동의 기록(만 14세 미만은 보호자 동의) · 회원 탈퇴
-- migration_006 실행 후, Supabase SQL Editor에서 실행하세요. (여러 번 실행해도 안전)

-- 1) 운동 기록 수정
--    회원: 본인 기록 중 PT가 아닌 것 / 트레이너: 담당 회원의 PT 기록·가져온 기록 (입력 규칙과 같음)
drop policy if exists logs_update on public.workout_logs;
create policy logs_update on public.workout_logs for update
  using ((user_id = auth.uid() and is_pt = false)
      or (public.is_my_member(user_id) and (is_pt = true or imported = true)))
  with check ((user_id = auth.uid() and is_pt = false)
      or (public.is_my_member(user_id) and (is_pt = true or imported = true)));

-- 누구의 기록인지, PT/가져온 기록 여부는 수정으로 바꿀 수 없다
create or replace function public.guard_log_update() returns trigger
language plpgsql as $$
begin
  new.user_id := old.user_id; new.is_pt := old.is_pt; new.imported := old.imported; new.created_at := old.created_at;
  return new;
end $$;
drop trigger if exists workout_logs_guard on public.workout_logs;
create trigger workout_logs_guard before update on public.workout_logs
  for each row execute function public.guard_log_update();

-- 2) 약관 동의 기록
alter table public.profiles add column if not exists terms_agreed_at timestamptz;
alter table public.profiles add column if not exists under14 boolean not null default false;
alter table public.profiles add column if not exists guardian_agreed boolean not null default false;

-- 이메일 가입은 가입 폼에서 동의한 내용(메타데이터)을 바로 기록한다
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
  ) on conflict (id) do nothing;
  return new;
end $$;

-- 소셜 가입·기존 회원은 앱에서 동의하면 서버 시각으로 기록
create or replace function public.agree_terms(p_under14 boolean, p_guardian boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception '로그인이 필요해요'; end if;
  if coalesce(p_under14, false) and not coalesce(p_guardian, false) then
    raise exception '만 14세 미만은 보호자(법정대리인) 동의가 필요해요';
  end if;
  update profiles set terms_agreed_at = now(), under14 = coalesce(p_under14, false),
         guardian_agreed = coalesce(p_guardian, false)
  where id = auth.uid();
end $$;
revoke execute on function public.agree_terms(boolean, boolean) from public, anon;
grant execute on function public.agree_terms(boolean, boolean) to authenticated;

-- 3) 회원 탈퇴: 내 프로필과 모든 기록(운동·인바디·PT·노트)을 지우고 로그인 계정도 삭제한다.
--    트레이너가 직접 등록한 '앱 미사용 회원'은 그 트레이너만 볼 수 있으므로 함께 지운다.
--    다른 회원의 담당 트레이너였다면 그 회원들은 '강사 미연결' 상태가 된다(trainer_id → null).
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception '로그인이 필요해요'; end if;
  delete from public.profiles where is_managed and trainer_id = me;
  delete from public.profiles where id = me;
  delete from auth.users where id = me;
end $$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
