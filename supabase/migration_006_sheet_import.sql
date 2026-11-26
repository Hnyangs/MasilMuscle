-- 006: 구글 시트 운동 기록 가져오기 (회원코드로 매핑)
-- 트레이너가 앱에서 시트 CSV를 올리면 회원코드의 회원에게 기록이 들어간다.
-- 시트에는 PT 기록과 회원 개인 운동이 섞여 있으므로, 트레이너가 담당 회원에게 PT가 아닌 기록도
-- "가져온 기록(imported)"으로는 넣을 수 있게 정책을 넓힌다. (일반 입력은 기존 규칙 그대로)
-- migration_005 실행 후, Supabase SQL Editor에서 실행하세요. (여러 번 실행해도 안전)

alter table public.workout_logs add column if not exists imported boolean not null default false;

drop policy if exists logs_insert on public.workout_logs;
create policy logs_insert on public.workout_logs for insert with check (
  (user_id = auth.uid() and is_pt = false)
  or (public.is_my_member(user_id) and (is_pt = true or imported = true))
);
