const STALE_MS = 15 * 60 * 1000;
const FUTURE_SKEW_MS = 60 * 1000;

export async function evaluate(res, now) {
  if (!res.ok) return { ok: false, cls: "http", why: `status.json ${res.status}` };
  let body;
  try {
    body = await res.json();
  } catch {
    return { ok: false, cls: "nojson", why: "status.json body not valid JSON" };
  }
  const generated = Date.parse(body.generated);
  if (Number.isNaN(generated)) return { ok: false, cls: "stale", why: "no timestamp in status.json" };
  const age = now - generated;
  if (age < -FUTURE_SKEW_MS) {
    return { ok: false, cls: "stale", why: "clock skew: generated is in the future" };
  }
  if (!(age < STALE_MS)) return { ok: false, cls: "stale", why: `stale ${Math.round(age / 60000)} min` };
  if (body.ok !== true) {
    const red = Object.entries(body.checks || {}).filter(([, v]) => v !== true).map(([k]) => k);
    const sorted = [...red].sort();
    return { ok: false, cls: `red:${sorted.join(",") || "unknown"}`, why: `red: ${red.join(", ") || "unknown"}` };
  }
  return { ok: true, cls: "ok", why: "ok" };
}

export default {
  async scheduled(_event, env) {
    let verdict;
    try {
      const res = await fetch(env.STATUS_URL, { signal: AbortSignal.timeout(10000), cache: "no-store" });
      verdict = await evaluate(res, Date.now());
    } catch (e) {
      verdict = { ok: false, cls: "unreachable", why: `unreachable: ${e.message}` };
    }
    const last = (await env.STATE.get("last")) || "ok";
    if (verdict.cls === last) return;

    const wasOk = last === "ok";
    let title;
    let priority;
    let tags;
    if (wasOk) {
      title = "homelab DOWN";
      priority = "high";
      tags = "rotating_light";
    } else if (verdict.ok) {
      title = "homelab recovered";
      priority = "default";
      tags = "white_check_mark";
    } else {
      title = `homelab still DOWN: ${verdict.why}`;
      priority = "high";
      tags = "rotating_light";
    }

    let ntfyRes;
    try {
      ntfyRes = await fetch(`https://ntfy.sh/${env.NTFY_TOPIC}`, {
        method: "POST",
        headers: { Title: title, Priority: priority, Tags: tags },
        body: `${verdict.why} (${new Date().toISOString()})`,
      });
    } catch {
      ntfyRes = null;
    }
    // Only persist the new state once the alert actually went out; on
    // failure leave "last" as-is so the next tick retries the push.
    if (ntfyRes && ntfyRes.ok) {
      await env.STATE.put("last", verdict.cls);
    }
  },
};
