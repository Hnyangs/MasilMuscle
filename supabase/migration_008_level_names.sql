-- 008: 운동 등급 이름 변경 (헬린이 · 헬스러 · 헬창 · 고인물 · 선수)
-- 등급은 앱이 운동 기록으로 자동 계산해 profiles.level 에 저장한다. 이전 값(초급/중급/고급)도 계속 허용한다.
-- migration_007 실행 후, Supabase SQL Editor에서 실행하세요. (여러 번 실행해도 안전)

alter table public.profiles drop constraint if exists profiles_level_check;
alter table public.profiles add constraint profiles_level_check
  check (level in ('초급','중급','고급','헬린이','헬스러','헬창','고인물','선수'));
