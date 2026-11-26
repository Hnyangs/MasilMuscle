// 네이버 로그인 → Supabase 세션 발급 (Supabase Edge Function, Deno)
//
// Supabase는 네이버를 기본 OAuth 공급자로 지원하지 않으므로 이 함수가 대신 처리한다.
//   1) action "start"    : 네이버 로그인 주소를 만들어 돌려준다 (Client ID만 사용)
//   2) action "callback" : 네이버가 돌려준 code로 토큰·프로필을 받고, Supabase 사용자를 만들거나 찾아
//                          access/refresh 토큰을 돌려준다. 앱은 sb.auth.setSession()으로 로그인한다.
//
// 필요한 시크릿 (Dashboard > Edge Functions > Secrets): NAVER_CLIENT_ID, NAVER_CLIENT_SECRET
// SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY 는 Supabase가 자동으로 넣어 준다.
// 배포: supabase functions deploy naver-auth --no-verify-jwt   (대시보드 편집기라면 "Verify JWT" 끄기)
//
// 계정 키는 네이버 고유 id로 만든 내부 이메일(naver_<id>@naver.invalid)이다. 네이버 프로필의 이메일로
// 기존 계정에 합치지 않는 이유: 네이버 연락처 이메일은 본인 소유가 검증되지 않아, 남의 이메일을 적어
// 그 계정으로 로그인하는 탈취가 가능해진다. 실제 이메일은 profiles.email(트레이너 검색용)에만 넣는다.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const env = (k) => {
  const v = Deno.env.get(k);
  if (!v) throw new Error(`Edge Function 시크릿 ${k}가 설정되지 않았어요`);
  return v;
};
const noSession = { auth: { persistSession: false, autoRefreshToken: false } };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const { action, code, state, redirect_uri } = await req.json();
    const clientId = env("NAVER_CLIENT_ID");

    if (action === "start") {
      if (!redirect_uri || !state) return json({ error: "redirect_uri와 state가 필요해요" }, 400);
      const u = new URL("https://nid.naver.com/oauth2.0/authorize");
      u.search = new URLSearchParams({ response_type: "code", client_id: clientId, redirect_uri, state }).toString();
      return json({ url: u.toString() });
    }
    if (action !== "callback" || !code || !state) return json({ error: "잘못된 요청이에요" }, 400);

    // 1) code → 네이버 access token
    const tok = await (await fetch("https://nid.naver.com/oauth2.0/token?" + new URLSearchParams({
      grant_type: "authorization_code", client_id: clientId, client_secret: env("NAVER_CLIENT_SECRET"), code, state,
    }))).json();
    if (!tok.access_token) return json({ error: "네이버 인증 실패: " + (tok.error_description || tok.error || "토큰 없음") }, 400);

    // 2) 네이버 프로필
    const me = await (await fetch("https://openapi.naver.com/v1/nid/me", {
      headers: { Authorization: `Bearer ${tok.access_token}` },
    })).json();
    const p = me.response;
    if (me.resultcode !== "00" || !p?.id) return json({ error: "네이버 프로필을 가져오지 못했어요" }, 400);

    const url = env("SUPABASE_URL");
    const admin = createClient(url, env("SUPABASE_SERVICE_ROLE_KEY"), noSession);
    const email = `naver_${String(p.id).replace(/[^A-Za-z0-9_-]/g, "")}@naver.invalid`;
    const name = p.name || p.nickname || "";

    // 3) 사용자 생성 (이미 있으면 그대로 사용)
    const created = await admin.auth.admin.createUser({
      email, email_confirm: true,
      user_metadata: { name, full_name: name, naver_email: p.email ?? null },
      app_metadata: { provider: "naver", providers: ["naver"] },
    });
    const isNew = !created.error;
    if (created.error && !/already|registered|exists/i.test(created.error.message)) throw created.error;

    // 4) 매직링크 토큰을 서버에서 바로 검증해 세션 발급 (메일은 보내지 않음)
    const link = await admin.auth.admin.generateLink({ type: "magiclink", email });
    if (link.error) throw link.error;
    if (isNew) {
      const up = await admin.from("profiles").upsert(
        { id: link.data.user.id, email: (p.email || "").toLowerCase() || email, name, onboarded: false },
        { onConflict: "id" },
      );
      if (up.error) throw new Error("프로필 저장 실패 (migration_004 실행 여부 확인): " + up.error.message);
    }
    const anon = createClient(url, env("SUPABASE_ANON_KEY"), noSession);
    const v = await anon.auth.verifyOtp({ token_hash: link.data.properties.hashed_token, type: "magiclink" });
    if (v.error || !v.data.session) throw v.error || new Error("세션을 만들지 못했어요");

    return json({ access_token: v.data.session.access_token, refresh_token: v.data.session.refresh_token });
  } catch (e) {
    return json({ error: String(e?.message || e) }, 500);
  }
});
