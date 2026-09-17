const STALE_MS = 15 * 60 * 1000;

export async function evaluate(res, now) {
  if (!res.ok) return { ok: false, why: `status.json ${res.status}` };
  let body;
  try {
    body = await res.json();
  } catch {
    return { ok: false, why: "status.json body not valid JSON" };
  }
  const generated = Date.parse(body.generated);
  if (Number.isNaN(generated)) return { ok: false, why: "no timestamp in status.json" };
  const age = now - generated;
  if (!(age < STALE_MS)) return { ok: false, why: `stale ${Math.round(age / 60000)} min` };
  if (body.ok !== true) {
    const red = Object.entries(body.checks || {}).filter(([, v]) => v !== true).map(([k]) => k);
    return { ok: false, why: `red: ${red.join(", ") || "unknown"}` };
  }
  return { ok: true, why: "ok" };
}

export default {
  async scheduled(_event, env) {
    let verdict;
    try {
      const res = await fetch(env.STATUS_URL, { signal: AbortSignal.timeout(10000) });
      verdict = await evaluate(res, Date.now());
    } catch (e) {
      verdict = { ok: false, why: `unreachable: ${e.message}` };
    }
    const last = (await env.STATE.get("last")) || "ok";
    const nowState = verdict.ok ? "ok" : "down";
    if (nowState !== last) {
      const title = verdict.ok ? "homelab recovered" : "homelab DOWN";
      let ntfyRes;
      try {
        ntfyRes = await fetch(`https://ntfy.sh/${env.NTFY_TOPIC}`, {
          method: "POST",
          headers: { Title: title, Priority: verdict.ok ? "default" : "high", Tags: verdict.ok ? "white_check_mark" : "rotating_light" },
          body: `${verdict.why} (${new Date().toISOString()})`,
        });
      } catch {
        ntfyRes = null;
      }
      // Only persist the new state once the alert actually went out; on
      // failure leave "last" as-is so the next tick retries the push.
      if (ntfyRes && ntfyRes.ok) {
        await env.STATE.put("last", nowState);
      }
    }
  },
};
