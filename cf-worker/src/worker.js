// ӾChat node front — a stable, short, free workers.dev hostname that reverse-proxies to a home node whose
// public URL churns (a Cloudflare quick tunnel). The current backend origin lives in KV key "backend",
// refreshed by the home machine on every (re)start. We announce THIS worker URL on the XNO ledger: short
// enough for the 32-byte on-chain link and never changing, while the worker forwards to wherever the node
// lives now. Home machine offline → backend fetch fails → 502, and the app's /api/status probe falls back.
export default {
  async fetch(request, env) {
    const backend = (await env.BACKEND_KV.get("backend") || "").replace(/\/+$/, "");
    if (!backend) return json({ error: "no backend registered yet" }, 503);
    const url = new URL(request.url);
    const headers = new Headers(request.headers);
    headers.delete("host"); // let fetch set Host from the target origin
    const init = { method: request.method, headers, redirect: "manual" };
    if (request.method !== "GET" && request.method !== "HEAD") init.body = request.body;
    try {
      const resp = await fetch(backend + url.pathname + url.search, init);
      const out = new Headers(resp.headers);
      out.set("x-xchat-front", "worker");
      return new Response(resp.body, { status: resp.status, headers: out });
    } catch (e) {
      return json({ error: "backend unreachable", detail: String(e) }, 502);
    }
  },
};
function json(obj, status) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
}
