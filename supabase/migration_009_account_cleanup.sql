-- 009: 계정 삭제 시 프로필·수업 일정 정리
-- migration_005 에서 profiles.id → auth.users 외래키를 풀었기 때문에, Supabase 대시보드에서 사용자(auth.users)를
-- 지우면 profiles 와 그에 딸린 PT 일정·기록이 남는다. auth.users 행이 지워질 때 프로필도 함께 지운다.
--  · 트레이너가 지워지면: 그 트레이너의 PT 일정, 직접 등록한 앱 미사용 회원, 회원 메모가 함께 지워지고
--    담당 회원은 '강사 미연결'(trainer_id null)이 된다.
--  · 회원이 지워지면: 그 회원의 기록·인바디·PT 일정이 함께 지워진다.
-- migration_008 실행 후, Supabase SQL Editor에서 실행하세요. (여러 번 실행해도 안전)

create or replace function public.handle_user_deleted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.pt_schedules where trainer_id = old.id or member_id = old.id;
  delete from public.profiles where is_managed and trainer_id = old.id;
  delete from public.profiles where id = old.id;
  return old;
end $$;

drop trigger if exists on_auth_user_deleted on auth.users;
create trigger on_auth_user_deleted after delete on auth.users
  for each row execute function public.handle_user_deleted();

-- 앱의 '회원 탈퇴'도 PT 일정을 명시적으로 지운다 (외래키 cascade 에 더해)
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception '로그인이 필요해요'; end if;
  delete from public.pt_schedules where trainer_id = me or member_id = me
     or member_id in (select id from public.profiles where is_managed and trainer_id = me);
  delete from public.profiles where is_managed and trainer_id = me;
  delete from public.profiles where id = me;
  delete from auth.users where id = me;
end $$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
