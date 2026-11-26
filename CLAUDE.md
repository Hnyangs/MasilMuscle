# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

MasilMuscle is a Korean-language, mobile-first workout log PWA-style web app (UI strings are in Korean; page title "MasilMuscle"). The entire app is a single static file, `index.html` (inline `<style>` + one inline `<script>`). There is no build system, package manager, linter, or test suite, and no README or Cursor/Copilot rules.

## Running

No build step. Open `index.html` in a browser, or serve it statically (e.g. `python3 -m http.server`) and view at mobile width (the layout is capped at `max-width:480px`). There are no tests; verify changes by loading the page (e.g. with Playwright) and exercising the UI.

## Architecture

Vanilla JS with no framework or modules. Everything lives in the one `<script>`, in this order: constants → state → utils → recommendation logic → views → sheet sync → seed data → render.

- **State**: one global object `S`, persisted wholesale to `localStorage` under key `fitlog-v1` via `save()`. Shape: `{user, settings, workouts[], pt[], inbody[], customEx{}}`. Mutate `S`, call `save()`, then `render()`. Changing the shape needs backward-compatible handling of existing stored data (the key is not versioned per-change).
- **Rendering**: no virtual DOM. `render()` rebuilds `#app` innerHTML from template strings: `loginView()` when `S.user` is null, otherwise the view for the current `tab` (`home|record|pt|inbody|settings`) plus the bottom nav. Event handlers are inline `onclick="fn(...)"` attributes, so handler functions must stay global. Always pass user-provided text through `esc()` when interpolating into templates. `draft` holds the in-progress workout being edited on the record tab; `go(tab)` switches tabs.
- **Roles**: `S.user.role` is `trainer` or `member` (switchable in settings via `switchRole`). Trainers write PT session notes (`S.pt`); members see them, and unread ones show a badge on the nav and are marked read when the PT tab is opened.
- **Recommendation engine** (`recommend`, `suggest`, `topExercises`): `S.settings.split` is `auto` (the longest-rested of 가슴/등/하체/어깨, via `restDays`) or a split from `SPLITS` (2/3/4/full), which picks the day whose first part has rested longest. `suggest(ex)` does progressive overload from the last record: all sets ≥12 reps → add weight (+2.5kg if ≥40kg, else +1), any set <6 reps → hold, otherwise add reps. `PARTS`, `DEFAULT_EX`, and `SPLITS` define the domain data; custom exercises go in `S.customEx[part]`.
- **Google Sheets sync (optional)**: the user supplies a Google Apps Script web-app URL and token in settings. `pushSheet` POSTs `{token,type,rows}` with `mode:'no-cors'` (fire-and-forget; failures only toast, local data is kept). `pullSheet` GETs `?type=운동기록&token=...` and **replaces** local workouts after confirmation. It depends on Korean sheet column names (`날짜`, `부위`, `운동`, `무게`, `횟수`) and the Apps Script itself is not in this repo.
- **Notifications**: `checkNotify` runs on a 30s `setInterval` while the page is open, using the Web Notification API with a toast fallback; there is no service worker or background push.
- **Dates**: use `todayStr()` / `localDate()` (timezone-corrected `YYYY-MM-DD`) rather than `toISOString()` directly; records compare by date string (`byDate`).
- `seed()` populates sample data for demos.
