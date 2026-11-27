-- 믓 Supabase 통합 설정: 새 프로젝트(dev 등)에서 이 파일 하나를 SQL Editor에 붙여넣고 Run 하면 됩니다.
-- 아래 파일을 순서대로 이어 붙인 것입니다: schema.sql, exercises.sql, migration_002_mypage_inbody.sql, migration_003_inbody_fields.sql, migration_004_social_login.sql, migration_005_trainer_tools.sql, migration_006_sheet_import.sql, migration_007_edit_consent_withdraw.sql, migration_008_level_names.sql, migration_009_account_cleanup.sql
-- 여러 번 실행해도 안전합니다(이미 있는 것은 건너뛰거나 덮어씀). 데이터는 지우지 않습니다.
-- 이 파일은 생성물입니다. 원본 SQL을 바꾸면 CLAUDE.md의 'Environments' 항목에 적힌 명령으로 다시 만드세요.

-- ======================================================================
-- schema.sql
-- ======================================================================
-- 믓 Supabase 스키마. Supabase 대시보드 > SQL Editor에서 한 번 실행하세요.
-- (Authentication > Providers > Email 사용. 이메일 인증을 켜 두면 가입 후 인증 메일 확인이 필요합니다.)

create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  email text,
  name text not null default '',
  role text not null default 'member' check (role in ('member','trainer')),
  level text not null default '초급' check (level in ('초급','중급','고급')),
  trainer_id uuid references public.profiles(id) on delete set null,
  notes text not null default '',
  curriculum text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists profiles_email_idx on public.profiles (email);
create index if not exists profiles_trainer_idx on public.profiles (trainer_id);

create table if not exists public.workout_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  log_date date not null default current_date,
  part text not null,                    -- exercises.body_part 값 (제한 없음; 종목 목록은 supabase/exercises.sql)
  exercise text not null,
  sets jsonb not null default '[]',      -- [{"w": 60, "r": 10}, ...] (w: kg, r: reps)
  feedback text not null default '',
  is_pt boolean not null default false,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists workout_logs_user_idx on public.workout_logs (user_id, log_date desc);

create table if not exists public.pt_schedules (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.profiles(id) on delete cascade,
  trainer_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  pt_date date not null,
  pt_time time not null,
  goal text not null default '',
  status text not null default 'scheduled' check (status in ('scheduled','completed','canceled')),
  created_at timestamptz not null default now()
);
create index if not exists pt_member_idx on public.pt_schedules (member_id, pt_date);

-- 가입 시 auth 메타데이터(name, role, level)로 profiles 자동 생성 (이메일 인증 전에도 동작)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name, role, level)
  values (
    new.id, lower(new.email),
    coalesce(new.raw_user_meta_data->>'name', ''),
    case when new.raw_user_meta_data->>'role' = 'trainer' then 'trainer' else 'member' end,
    case when new.raw_user_meta_data->>'level' in ('초급','중급','고급') then new.raw_user_meta_data->>'level' else '초급' end
  ) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- RLS 정책이 profiles를 다시 조회할 때 재귀되지 않도록 security definer 함수 사용
create or replace function public.is_trainer() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and role = 'trainer') $$;
create or replace function public.my_trainer_id() returns uuid
language sql stable security definer set search_path = public as
$$ select trainer_id from profiles where id = auth.uid() $$;
create or replace function public.is_my_member(uid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = uid and trainer_id = auth.uid()) $$;

alter table public.profiles enable row level security;
alter table public.workout_logs enable row level security;
alter table public.pt_schedules enable row level security;

-- profiles: 본인 / 내 담당 회원 / 내 트레이너 / (트레이너가 이메일로 회원 검색)
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select using (
  id = auth.uid() or trainer_id = auth.uid() or id = public.my_trainer_id()
  or (public.is_trainer() and role = 'member'));
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert with check (id = auth.uid());
-- 트레이너만 회원 프로필 수정 가능(미배정 회원을 내 회원으로 등록, 노트/커리큘럼 작성)
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update
  using (public.is_trainer() and role = 'member' and (trainer_id is null or trainer_id = auth.uid()))
  with check (role = 'member' and trainer_id = auth.uid());

-- workout_logs: 본인 기록 또는 내 담당 회원 기록
drop policy if exists logs_select on public.workout_logs;
create policy logs_select on public.workout_logs for select using (user_id = auth.uid() or public.is_my_member(user_id));
drop policy if exists logs_insert on public.workout_logs;
create policy logs_insert on public.workout_logs for insert with check (
  (user_id = auth.uid() and is_pt = false) or (public.is_my_member(user_id) and is_pt = true));
drop policy if exists logs_delete on public.workout_logs;
create policy logs_delete on public.workout_logs for delete using (user_id = auth.uid() or public.is_my_member(user_id));

-- pt_schedules: 회원은 조회만, 담당 트레이너는 관리
drop policy if exists pt_select on public.pt_schedules;
create policy pt_select on public.pt_schedules for select using (member_id = auth.uid() or trainer_id = auth.uid());
drop policy if exists pt_insert on public.pt_schedules;
create policy pt_insert on public.pt_schedules for insert with check (trainer_id = auth.uid() and public.is_my_member(member_id));
drop policy if exists pt_update on public.pt_schedules;
create policy pt_update on public.pt_schedules for update using (trainer_id = auth.uid()) with check (trainer_id = auth.uid() and public.is_my_member(member_id));
drop policy if exists pt_delete on public.pt_schedules;
create policy pt_delete on public.pt_schedules for delete using (trainer_id = auth.uid());

-- ======================================================================
-- exercises.sql
-- ======================================================================
-- 운동 종목 마스터 테이블 + 시드 데이터. Supabase SQL Editor에서 실행 (여러 번 실행해도 안전).
-- body_part: 전신, 하체, 등, 가슴, 어깨, 이두, 삼두, 복근_신전근, 필라테스, 애니멀플로우, BASIC

create table if not exists public.exercises (
  id bigint generated always as identity primary key,   -- 입력 순서 = 화면 표시 순서
  body_part text not null check (char_length(body_part) between 1 and 30),
  name text not null check (char_length(name) between 1 and 60),
  created_at timestamptz not null default now(),
  unique (body_part, name)
);

alter table public.exercises enable row level security;
drop policy if exists exercises_select on public.exercises;
drop policy if exists exercises_insert on public.exercises;
-- 로그인한 사용자는 누구나 조회 / 새 종목 추가 가능 (수정·삭제는 불가)
create policy exercises_select on public.exercises for select to authenticated using (true);
create policy exercises_insert on public.exercises for insert to authenticated with check (true);

-- 앱이 전신/이두/삼두/필라테스 등 새 부위로 기록하므로 workout_logs.part의 5개 부위 제한을 해제
alter table public.workout_logs drop constraint if exists workout_logs_part_check;

insert into public.exercises (body_part, name) values
  ('전신', '케틀벨 클린&프레스'),
  ('하체', '백 스쿼트'),
  ('등', '풀업'),
  ('가슴', '푸쉬업'),
  ('어깨', '오버헤드프레스'),
  ('이두', '케이블 컬'),
  ('삼두', '케이블 푸쉬다운'),
  ('복근_신전근', '크리스 크로스'),
  ('필라테스', '체어 스완'),
  ('애니멀플로우', 'Beast Lift'),
  ('BASIC', '호흡체크'),
  ('전신', '케틀벨 런지&프레스'),
  ('하체', '백 스쿼트(스미스)'),
  ('등', '풀업(밴드)'),
  ('가슴', '벤치프레스(플랫)'),
  ('어깨', '오버헤드프레스(덤벨)'),
  ('이두', '케이블 리버스 컬'),
  ('삼두', '케이블 킥백'),
  ('복근_신전근', '원레그스트레치'),
  ('필라테스', '친인'),
  ('애니멀플로우', 'Beast Travelling'),
  ('BASIC', '테이블탑'),
  ('전신', '케틀벨 클린&스쿼트'),
  ('하체', '프론트 스쿼트'),
  ('등', '풀업(어시스트)'),
  ('가슴', '벤치프레스(인클라인)'),
  ('어깨', '숄더프레스(덤벨)'),
  ('이두', '덤벨 컬'),
  ('삼두', '오버헤드 트라이셉스 익스텐션(케이블)'),
  ('복근_신전근', '시저'),
  ('필라테스', '넥컬'),
  ('애니멀플로우', 'Loaded Beast'),
  ('BASIC', '데드버그'),
  ('전신', '바벨 클린&프레스'),
  ('하체', '프론트 스쿼트(케틀벨)'),
  ('등', '오버그립 바벨로우'),
  ('가슴', '덤벨 벤치프레스(인클라인)'),
  ('어깨', '숄더프레스(머신)'),
  ('이두', '케이블 헤머 컬'),
  ('삼두', '오버헤드 트라이셉스 익스텐션(덤벨)'),
  ('복근_신전근', '크런치'),
  ('필라테스', '컬업'),
  ('애니멀플로우', 'Beast Reach'),
  ('BASIC', '버드독'),
  ('전신', '랜드마인 스쿼트&프레스'),
  ('하체', '프론트 스쿼트(샌드백)'),
  ('등', '언더그립 바벨로우'),
  ('가슴', '덤벨 벤치프레스(플랫)'),
  ('어깨', '숄더프레스(케이블)'),
  ('이두', '덤벨 헤머 컬'),
  ('삼두', '덤벨 킥백'),
  ('복근_신전근', '플랭크'),
  ('필라테스', '헌드레드'),
  ('애니멀플로우', 'Beast Unload Wave 🌊'),
  ('BASIC', '하프레그레이즈'),
  ('전신', '렌드마인 런지&프레스'),
  ('하체', '풀 스쿼트'),
  ('등', '원암 덤벨로우'),
  ('가슴', '머신 벤치프레스(인클라인)'),
  ('어깨', '시티드 숄더프레스(덤벨)'),
  ('이두', '인클라인 덤벨 컬'),
  ('삼두', '라잉 오버헤드 트라이셉스 익스텐션'),
  ('복근_신전근', '사이드 플랭크'),
  ('필라테스', '힌지백'),
  ('애니멀플로우', 'Beast Unload'),
  ('BASIC', '덩키킥'),
  ('전신', '샌드백 클린&스쿼트'),
  ('하체', 'V 스쿼트'),
  ('등', '덤벨로우'),
  ('가슴', '머신 벤치프레스(플랫)'),
  ('어깨', '시티드 숄더프레스(바벨)'),
  ('이두', '바벨컬'),
  ('삼두', '벤치 딥스'),
  ('복근_신전근', '슈퍼맨'),
  ('필라테스', '리포머 - 스쿼트'),
  ('애니멀플로우', 'Beast Scorpion🦂 reach'),
  ('BASIC', '버드독(오버헤드)'),
  ('전신', '덤벨 스쿼트&프레스'),
  ('하체', '불가리안 스플릿 스쿼트'),
  ('등', '암풀다운'),
  ('가슴', '스미스 벤치프레스(인클라인)'),
  ('어깨', '시티드 숄더프레스(스미스)'),
  ('이두', '리버스컬'),
  ('복근_신전근', '4point 로테이션'),
  ('필라테스', '리포머 - 원암오버헤드프레스'),
  ('애니멀플로우', 'Crocodile🐊 Crawl'),
  ('BASIC', '4point 힙힌지'),
  ('전신', '스쿼트&프레스'),
  ('하체', '점프 불가리안 스플릿 스쿼트'),
  ('등', '티바로우(랜드마인)'),
  ('가슴', '스미스 벤치프레스(플랫)'),
  ('어깨', '원암 케틀벨 숄더프레스'),
  ('복근_신전근', 'AB슬라이드'),
  ('필라테스', '리포머 - 스플릿 스쿼트'),
  ('애니멀플로우', 'Crab reach'),
  ('BASIC', '스텐딩 힙힌지'),
  ('전신', '윈드밀'),
  ('하체', '점프 스쿼트'),
  ('등', '티바로우(머신)'),
  ('가슴', '딥스'),
  ('어깨', '원암 리버스 케틀벨 숄더프레스'),
  ('복근_신전근', '트위스트 크런치'),
  ('필라테스', '리포머 - 원암 체스트 프레스'),
  ('BASIC', '닐링 힙힌지'),
  ('전신', '점핑잭'),
  ('하체', '피스톨 스쿼트'),
  ('등', '시티드 로우(언더그립)'),
  ('가슴', '딥스(어시스트)'),
  ('어깨', '비하인드 넥 프레스'),
  ('복근_신전근', '행잉 레그레이즈'),
  ('필라테스', '포트데브라'),
  ('BASIC', '벤치 힙힌지'),
  ('전신', '버피테스트'),
  ('하체', '맨몸 스쿼트'),
  ('등', '시티드 로우(오버그립)'),
  ('가슴', '펙덱플라이'),
  ('어깨', '비하인드 넥 프레스(머신)'),
  ('복근_신전근', '리버스 크런치'),
  ('필라테스', '바렐 - 풀 스완'),
  ('BASIC', '시티드 힙힌지'),
  ('전신', '하이니'),
  ('하체', '스플릿 스쿼트'),
  ('등', '시티드 로우(뉴트럴그립)'),
  ('가슴', '풀 오버'),
  ('어깨', '비하인드 넥 프레스(스미스)'),
  ('복근_신전근', '더블레그스트레치'),
  ('필라테스', '리포머 - 투 풋바 힙힌지'),
  ('BASIC', '하프닐링 힙힌지'),
  ('전신', '사이드 점프'),
  ('하체', '스플릿 스쿼트(스미스)'),
  ('등', '원암 시티드 로우'),
  ('가슴', '케이블플라이'),
  ('어깨', '리버스펙덱플라이'),
  ('복근_신전근', '레그레이즈'),
  ('필라테스', '리포머 - 투 스트랩 힙힌지'),
  ('BASIC', '프레첼스트레칭'),
  ('전신', '사이드 스텝'),
  ('하체', '스플릿 스쿼트(덤벨)'),
  ('등', '랫풀다운(오버그립)'),
  ('가슴', '케이블플라이(하이)'),
  ('어깨', '케이블 플라이'),
  ('복근_신전근', '팔로프 프레스'),
  ('필라테스', '체어 - 힙힌지&페달프레스'),
  ('BASIC', '프로그 스퀴즈'),
  ('전신', '암워킹'),
  ('하체', '와이드스쿼트'),
  ('등', '랫풀다운(언더그립)'),
  ('가슴', '케이블플라이(로우)'),
  ('어깨', '페이스풀'),
  ('복근_신전근', '토터치 크런치'),
  ('필라테스', '캐딜락 - 스텐딩 힙힌지'),
  ('BASIC', '스카풀라 무브먼트(굴곡)'),
  ('전신', '서전트'),
  ('하체', '와이드스쿼트(케틀벨)'),
  ('등', '랫풀다운(클로즈그립)'),
  ('가슴', '체스트 프레스(오버그립)'),
  ('어깨', '사레레(덤벨)'),
  ('복근_신전근', '스태빌리티 볼 롤 아웃'),
  ('필라테스', '캐딜락 - 풀업'),
  ('BASIC', '스카풀라 무브먼트(외전)'),
  ('전신', '제자리 점프'),
  ('하체', '원레그 스쿼트'),
  ('등', '랫풀다운(뉴트럴그립)'),
  ('가슴', '체스트 프레스(뉴트럴그립)'),
  ('어깨', '사레레(케이블)'),
  ('복근_신전근', '스태빌리티 볼 익스체인지'),
  ('필라테스', '체어 - 포워드 런지'),
  ('BASIC', '전거근 운동(비고)'),
  ('전신', '스텝업'),
  ('하체', '사이드런지'),
  ('등', '랫풀다운(맥그립)'),
  ('가슴', '웨이브 푸시업'),
  ('어깨', '사이드라잉 사레레'),
  ('복근_신전근', '코펜하겐 플랭크'),
  ('필라테스', '바렐 - 라운드백'),
  ('BASIC', '크램쉘'),
  ('전신', '플랭크'),
  ('하체', '사이드런지(케틀벨)'),
  ('등', '랫풀다운(와이드 맥그립)'),
  ('가슴', '덤벨 플라이(플랫)'),
  ('어깨', '벤레레'),
  ('복근_신전근', 'v-up'),
  ('필라테스', '바렐 - 라운드백(PRE)'),
  ('BASIC', '리버스 크램쉘'),
  ('전신', '플랭크 케틀벨 로우'),
  ('하체', '스쿼트&런지'),
  ('등', '풀오버'),
  ('가슴', '덤벨 플라이(인클라인)'),
  ('어깨', '케이블 리버스 플라이(투암)'),
  ('복근_신전근', '스타피쉬 사이드 플랭크'),
  ('필라테스', '바렐 - 프론 스완'),
  ('BASIC', '밴디드 백 펄스'),
  ('전신', '플랭크 패쓰쓰루'),
  ('하체', '리버스 런지'),
  ('등', '루마니안 데드리프트'),
  ('가슴', '체스트 프레스(케이블)'),
  ('어깨', '케이블 리버스 플라이(원암)'),
  ('필라테스', '캐딜락 - 핸드스트랩 하프닐링 프레스'),
  ('BASIC', '밴디드 프론트 펄스'),
  ('전신', '플랭크 숄더탭'),
  ('하체', '컬시 런지'),
  ('등', '하이로우(머신)'),
  ('어깨', '스키점프'),
  ('필라테스', '바렐 - 오블리크 플렉션'),
  ('BASIC', 'Y밸런스'),
  ('전신', '플랭크 푸시업'),
  ('하체', '3D 런지'),
  ('등', '로터리 렛풀다운'),
  ('어깨', '프론트 레이즈(덤벨)'),
  ('필라테스', '롤바 - 리버스 노르딕 컬'),
  ('BASIC', 'T레이즈'),
  ('전신', '마운틴클라이밍'),
  ('하체', '워킹런지'),
  ('등', '롱풀(머신)'),
  ('어깨', '프론트 레이즈(케이블)'),
  ('필라테스', '리포머 - 투 스트렙 하프닐링 로테이션'),
  ('BASIC', 'Y레이즈'),
  ('전신', '케틀벨 클린'),
  ('하체', '컨벤셔널 데드리프트'),
  ('등', '암풀다운(로프)'),
  ('어깨', '플랭크 돌핀'),
  ('필라테스', '리포머 - 투 풋바 하프닐링 로테이션'),
  ('BASIC', 'W레이즈'),
  ('전신', '샌드백 클린'),
  ('하체', '루마니안 데드리프트'),
  ('등', '인버티드 로우'),
  ('어깨', '시티드 OARK S.P'),
  ('필라테스', '트라페즈 - 힙브릿지'),
  ('BASIC', '코브라'),
  ('전신', '원레그 하이니'),
  ('하체', '원레그 데드리프트'),
  ('등', '케틀벨 로우'),
  ('어깨', 'K.B HALO'),
  ('필라테스', '트라페즈 - 원레그 힙브릿지'),
  ('BASIC', '원레그 스텐딩'),
  ('전신', '런지'),
  ('하체', '원레그 데드리프트(스미스)'),
  ('등', '케이블 로우'),
  ('어깨', '아놀드 프레스'),
  ('필라테스', '트라페즈 - 힙브릿지+컬'),
  ('BASIC', '하프닐링 월 푸시'),
  ('전신', '파머스 캐리'),
  ('하체', '케틀벨 루마니안 데드리프트'),
  ('등', '밴디드 로우'),
  ('어깨', '오버헤드슈러그'),
  ('필라테스', '롤바 - 원암 원레그 데드리프트'),
  ('BASIC', '4point 펠빅로테이션'),
  ('전신', '스텝박스 - 점프 스쿼트'),
  ('하체', '샌드백 루마니안 데드리프트'),
  ('등', '페이크 풀업'),
  ('어깨', '덤벨 슈러그'),
  ('필라테스', '롤바 - 체스트 프레스'),
  ('BASIC', '펠빅 무브먼트'),
  ('전신', '스텝박스 - 로테이션 점프 스쿼트'),
  ('하체', '케틀벨 컨벤셔널 데드리프트'),
  ('등', '매달리기'),
  ('어깨', '바벨 슈러그'),
  ('필라테스', '바렐 - 스트레치 시리즈'),
  ('BASIC', '4point 스쿼트'),
  ('전신', '스텝박스 - 다운 점프 스쿼트'),
  ('하체', '샌드백 컨벤셔널 데드리프트'),
  ('어깨', '업라이트 로우'),
  ('필라테스', '바렐 - 벤트니'),
  ('BASIC', '푸쉬업플러스'),
  ('전신', '플랭크 니킥'),
  ('하체', '스티프데드리프트(덤벨)'),
  ('어깨', '스캡션'),
  ('필라테스', '롤바 - 롤업&롤다운'),
  ('BASIC', '사이드라잉 힙 모빌리티'),
  ('전신', '플랭크 트위스트'),
  ('하체', '스티프데드리프트(스미스)'),
  ('어깨', '팬듈럼'),
  ('필라테스', '리포머 - 체스트 플라이'),
  ('BASIC', '유산소'),
  ('전신', '런지&프레스'),
  ('하체', '레그프레스'),
  ('필라테스', '롤바 - 닐링힙힌지'),
  ('BASIC', '라잉 레그익스텐션'),
  ('전신', '레니게이드 로우'),
  ('하체', '레그컬'),
  ('필라테스', '캐딜락 - 스쿼트'),
  ('BASIC', '라잉 레그컬'),
  ('전신', 'PHA [상하지 교차 시스템]'),
  ('하체', '시티드 레그컬'),
  ('필라테스', '리포머 - 카프레이즈'),
  ('BASIC', '머메이드 힙힌지'),
  ('전신', '데빌 프레스'),
  ('하체', '노르딕컬'),
  ('필라테스', '리포머 - 힙브릿지'),
  ('BASIC', '포포지션 스트레칭'),
  ('전신', '플랭크 버드독'),
  ('하체', '레그익스텐션'),
  ('필라테스', '리포머 - 풋 스트랩 버드독'),
  ('BASIC', '스완 스트레칭'),
  ('전신', 'HIIT[고강도 인터벌 트레이닝]'),
  ('하체', '아웃타이'),
  ('필라테스', '리포머 - 플랭크'),
  ('BASIC', '머메이드 사이드 스트레칭'),
  ('전신', '스키어'),
  ('하체', '이너타이'),
  ('필라테스', '리포머 - 사이드플랭크'),
  ('BASIC', '하프닐링 로테이션'),
  ('전신', '점프 런지'),
  ('하체', '힙쓰러스트'),
  ('필라테스', '리포머 - 덩키킥'),
  ('BASIC', '케이블 데드리프트'),
  ('전신', '슬레드'),
  ('하체', '힙쓰러스트(머신)'),
  ('필라테스', '리포머 - 스완'),
  ('BASIC', '시티드 내전근 스트레칭'),
  ('전신', '로잉'),
  ('하체', '힙쓰러스트(스미스)'),
  ('필라테스', '롤업&롤다운'),
  ('BASIC', '폼롤러[비고]'),
  ('전신', '하이풀'),
  ('하체', '원레그 힙쓰러스트'),
  ('필라테스', '머메이드 스트레치'),
  ('BASIC', '스트레칭[비고]'),
  ('전신', '스파이더점프'),
  ('하체', '힙프레스'),
  ('필라테스', '체어 - 카프레이즈'),
  ('BASIC', '회전근개 운동[비고]'),
  ('전신', '배틀로프'),
  ('하체', '케틀벨 스윙'),
  ('필라테스', '체어 - 러닝'),
  ('BASIC', '힐업'),
  ('전신', '스내치'),
  ('하체', '케틀벨 스윙&스쿼트'),
  ('필라테스', '체어 - 롤다운&페달프레스'),
  ('BASIC', '밴디드 스윙'),
  ('전신', '불가리안 백 스윙'),
  ('하체', '플로어 카프레이즈'),
  ('필라테스', '티저'),
  ('BASIC', '캣카우'),
  ('하체', '스텝박스 카프레이즈'),
  ('필라테스', '체어 - 벤트니 스트레치'),
  ('BASIC', '4point 넥무브먼트'),
  ('하체', '원레그 카프레이즈'),
  ('필라테스', '체어 - 사이드 밴드'),
  ('BASIC', '넥 무브먼트'),
  ('하체', '힙익스텐션'),
  ('필라테스', '체어 - 시티드 페달프레스'),
  ('하체', '힙브릿지'),
  ('필라테스', '바렐 - 홀스백'),
  ('하체', '프로그 스쿼트'),
  ('필라테스', '체어 - 풀업'),
  ('하체', '원레그 힙브릿지'),
  ('필라테스', '리포머 - 롱토르소'),
  ('하체', 'S.S RDL'),
  ('필라테스', '리포머 - 엘리펀트'),
  ('하체', 'W-U 풀스퀏 / 발목스트레칭'),
  ('필라테스', '리포머 - 크런치'),
  ('하체', 'W-U 리자드 포즈 스트레칭'),
  ('필라테스', '바렐 - 사이드밴드'),
  ('하체', '힙에어플레인'),
  ('하체', '오버헤드스쿼트'),
  ('하체', '트랩바 데드리프트'),
  ('하체', '트랩바 스쿼트'),
  ('하체', '핵 스쿼트'),
  ('하체', '짐볼 힙브릿지'),
  ('하체', '짐볼 레그컬'),
  ('하체', 'W-U 피죤 스트레칭'),
  ('하체', '리버스 하이퍼'),
  ('하체', '사이드킥'),
  ('하체', '뎁스 점프'),
  ('하체', '원레그 케틀벨 스윙'),
  ('하체', '월 스쿼트'),
  ('하체', '시티드 레그프레스'),
  ('하체', '닐링스쿼트(스미스)'),
  ('하체', '힙하이크'),
  ('하체', '스모 컨벤셔널 데드리프트'),
  ('하체', '포워드 런지'),
  ('하체', '몬스터 워크'),
  ('하체', '크랩 워크'),
  ('하체', '케이블 킥백'),
  ('하체', '스패니쉬 스쿼트')
on conflict (body_part, name) do nothing;

-- ======================================================================
-- migration_002_mypage_inbody.sql
-- ======================================================================
-- 002: 마이페이지(내 정보) · 강사 코드 연결 · 인바디 · PT 신청 · 운동 노트
-- schema.sql / exercises.sql 실행 후, Supabase SQL Editor에서 전체를 한 번 실행하세요. (여러 번 실행해도 안전)

-- 1) 내 정보 컬럼 + 트레이너 코드
alter table public.profiles add column if not exists goal text not null default '';
alter table public.profiles add column if not exists height_cm numeric;
alter table public.profiles add column if not exists birth_date date;
alter table public.profiles add column if not exists start_weight numeric;
alter table public.profiles add column if not exists gender text not null default '';
alter table public.profiles add column if not exists trainer_code text;
create unique index if not exists profiles_trainer_code_key on public.profiles (trainer_code) where trainer_code is not null;

-- 2) 운동 기록 노트(트레이너 수업 메모 / 개인 메모)
alter table public.workout_logs add column if not exists note text not null default '';

-- 3) PT 신청 상태(requested) 추가
alter table public.pt_schedules drop constraint if exists pt_schedules_status_check;
alter table public.pt_schedules add constraint pt_schedules_status_check
  check (status in ('requested','scheduled','completed','canceled'));

-- 4) 인바디 기록
create table if not exists public.inbody_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  measured_on date not null default current_date,
  weight numeric,      -- 체중 kg
  muscle numeric,      -- 골격근량 kg
  fat_pct numeric,     -- 체지방률 %
  note text not null default '',
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists inbody_user_idx on public.inbody_records (user_id, measured_on desc);
alter table public.inbody_records enable row level security;
drop policy if exists inbody_select on public.inbody_records;
drop policy if exists inbody_insert on public.inbody_records;
drop policy if exists inbody_delete on public.inbody_records;
create policy inbody_select on public.inbody_records for select using (user_id = auth.uid() or public.is_my_member(user_id));
create policy inbody_insert on public.inbody_records for insert with check (user_id = auth.uid() or public.is_my_member(user_id));
create policy inbody_delete on public.inbody_records for delete using (user_id = auth.uid() or public.is_my_member(user_id));

-- 5) 본인 프로필 수정 허용 + 민감 컬럼 보호
--    본인이 직접 바꿀 수 있는 건 이름·숙련도·목표·키·생년월일·시작체중·성별뿐.
--    역할/담당 트레이너/노트/커리큘럼/코드는 아래 트리거가 원래 값으로 되돌림 (강사 연결은 link_trainer RPC로만)
create or replace function public.guard_profile_update() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.bypass_guard', true), '') <> '1'
     and auth.uid() is not null and auth.uid() = old.id then
    new.role := old.role; new.trainer_id := old.trainer_id; new.notes := old.notes;
    new.curriculum := old.curriculum; new.trainer_code := old.trainer_code; new.email := old.email;
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.guard_profile_update();

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- 6) 트레이너 코드 발급(4자리) / 회원의 강사 연결·해제
create or replace function public.my_trainer_code() returns text
language plpgsql security definer set search_path = public as $$
declare c text; tries int := 0;
begin
  if not public.is_trainer() then return null; end if;
  select trainer_code into c from profiles where id = auth.uid();
  if c is not null then return c; end if;
  perform set_config('app.bypass_guard', '1', true);
  loop
    c := lpad(floor(random() * 10000)::int::text, 4, '0');
    begin
      update profiles set trainer_code = c where id = auth.uid();
      return c;
    exception when unique_violation then
      tries := tries + 1; if tries > 50 then raise; end if;
    end;
  end loop;
end $$;

create or replace function public.link_trainer(code text) returns text
language plpgsql security definer set search_path = public as $$
declare t_id uuid; t_name text;
begin
  if not exists (select 1 from profiles where id = auth.uid() and role = 'member') then
    raise exception '회원 계정만 강사를 연결할 수 있어요';
  end if;
  select id, name into t_id, t_name from profiles where role = 'trainer' and trainer_code = trim(code);
  if t_id is null then raise exception '일치하는 강사 코드가 없어요'; end if;
  perform set_config('app.bypass_guard', '1', true);
  update profiles set trainer_id = t_id where id = auth.uid();
  return t_name;
end $$;

create or replace function public.unlink_trainer() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('app.bypass_guard', '1', true);
  update profiles set trainer_id = null where id = auth.uid() and role = 'member';
end $$;

revoke execute on function public.my_trainer_code() from public, anon;
revoke execute on function public.link_trainer(text) from public, anon;
revoke execute on function public.unlink_trainer() from public, anon;
grant execute on function public.my_trainer_code() to authenticated;
grant execute on function public.link_trainer(text) to authenticated;
grant execute on function public.unlink_trainer() to authenticated;

-- 7) 회원의 PT 신청 / 신청 취소
drop policy if exists pt_member_request on public.pt_schedules;
create policy pt_member_request on public.pt_schedules for insert
  with check (member_id = auth.uid() and status = 'requested' and trainer_id = public.my_trainer_id());
drop policy if exists pt_member_cancel on public.pt_schedules;
create policy pt_member_cancel on public.pt_schedules for update
  using (member_id = auth.uid() and status = 'requested')
  with check (member_id = auth.uid() and status = 'canceled');

-- ======================================================================
-- migration_003_inbody_fields.sql
-- ======================================================================
-- 003: 인바디에 체지방량 · 내장지방레벨 추가 (구글 시트 InBody 탭과 같은 입력 항목)
-- migration_002 실행 후, Supabase SQL Editor에서 실행하세요. (여러 번 실행해도 안전)
alter table public.inbody_records add column if not exists fat_mass numeric;      -- 체지방량 kg
alter table public.inbody_records add column if not exists visceral_fat numeric;  -- 내장지방레벨

-- ======================================================================
-- migration_004_social_login.sql
-- ======================================================================
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

-- ======================================================================
-- migration_005_trainer_tools.sql
-- ======================================================================
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

-- ======================================================================
-- migration_006_sheet_import.sql
-- ======================================================================
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

-- ======================================================================
-- migration_007_edit_consent_withdraw.sql
-- ======================================================================
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

-- ======================================================================
-- migration_008_level_names.sql
-- ======================================================================
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

-- ======================================================================
-- migration_009_account_cleanup.sql
-- ======================================================================
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
