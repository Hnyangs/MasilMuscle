-- 008: 운동 등급 이름 변경 (스타터 · 루티너 · 빌더 · 마스터 · 믓쟁이)
-- 등급은 앱이 운동 기록으로 자동 계산해 profiles.level 에 저장한다. 이전 값(초급/중급/고급, 중간에 쓰던 이름)도 계속 허용한다.
-- migration_007 실행 후, Supabase SQL Editor에서 실행하세요. (여러 번 실행해도 안전)

alter table public.profiles drop constraint if exists profiles_level_check;
alter table public.profiles add constraint profiles_level_check
  check (level in ('초급','중급','고급','헬린이','헬스러','헬창','고인물','선수','구경꾼','쇠맛','쇠질러','쇠박이',
                   '스타터','루티너','빌더','마스터','믓쟁이'));

-- 중간에 쓰인 이름을 새 이름으로 옮긴다. 초급/중급/고급은 앱이 로그인할 때 기록으로 다시 계산한다.
update public.profiles set level = case level
  when '헬린이' then '스타터' when '구경꾼' then '스타터'
  when '헬스러' then '루티너' when '쇠맛' then '루티너'
  when '헬창' then '빌더' when '쇠질러' then '빌더'
  when '고인물' then '마스터' when '쇠박이' then '마스터'
  when '선수' then '믓쟁이' end
where level in ('헬린이','헬스러','헬창','고인물','선수','구경꾼','쇠맛','쇠질러','쇠박이');
