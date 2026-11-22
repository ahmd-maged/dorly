// Short-lived proof that an e-mail address was verified with a one-time code.
// Signed with HMAC-SHA256 using the project's service-role key, which never leaves the server.
const enc = new TextEncoder();
const b64u = (buf: ArrayBuffer | Uint8Array) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fromB64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));

async function key() {
  return await crypto.subtle.importKey("raw", enc.encode("dorly-otp:" + Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

export async function makeToken(sub: string, purpose: string, ttlSec = 30 * 60) {
  const body = b64u(enc.encode(JSON.stringify({ sub, purpose, exp: Math.floor(Date.now() / 1000) + ttlSec })));
  const sig = b64u(await crypto.subtle.sign("HMAC", await key(), enc.encode(body)));
  return body + "." + sig;
}

export async function readToken(token: string): Promise<{ sub: string; purpose: string; exp: number } | null> {
  const [body, sig] = String(token || "").split(".");
  if (!body || !sig) return null;
  try {
    const ok = await crypto.subtle.verify("HMAC", await key(), fromB64u(sig), enc.encode(body));
    if (!ok) return null;
    const p = JSON.parse(new TextDecoder().decode(fromB64u(body)));
    return p.exp > Math.floor(Date.now() / 1000) ? p : null;
  } catch { return null; }
}

export async function sha256(s: string) {
  return b64u(await crypto.subtle.digest("SHA-256", enc.encode(s)));
}
