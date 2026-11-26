-- 003: 인바디에 체지방량 · 내장지방레벨 추가 (구글 시트 InBody 탭과 같은 입력 항목)
-- migration_002 실행 후, Supabase SQL Editor에서 실행하세요. (여러 번 실행해도 안전)
alter table public.inbody_records add column if not exists fat_mass numeric;      -- 체지방량 kg
alter table public.inbody_records add column if not exists visceral_fat numeric;  -- 내장지방레벨
