# Monitoring: free alerting on Cloudflare

A Cloudflare Worker (`monitoring/worker/`) polls the homelab's public status
feed and pushes to a phone via ntfy.sh when the mini goes stale or red. It
exists because a 2026-09-16 power loss went 11 hours with no alert: nothing
was watching the watcher.

## What it does

The mini's boot reconciler (`reconcile.sh`, runs every 10 minutes via
launchd) writes `status/html/status.json` with the shape:

```json
{"generated": "2026-09-17T20:05:28Z", "ok": true, "checks": {"colima": true, "doctor": true, "dns": true, "pihole_healthy": true, "apps": true, "serve": true}}
```

The Worker (`monitoring/worker/src/index.js`) runs on a Cron Trigger every 5
minutes, fetches that JSON over the public tunnel, and decides one of:

- **unreachable** — the fetch itself failed or timed out (10s)
- **stale** — `generated` is more than 15 minutes old, missing, or
  unparseable (the mini stopped publishing, or clocks disagree)
- **red** — `ok` is not `true`; the message names every check in `checks`
  whose value is not `true` (generic over whatever keys the reconciler adds)
- **ok** — fresh and green

## State machine

The Worker only cares about two states, `ok` and `down` (unreachable, stale,
and red all collapse to `down`). The last state is stored in KV
(`STATE["last"]`) so a push only fires on a transition:

```
ok -> down   : push "homelab DOWN: <reason>", priority high
down -> down : no push (already alerted)
down -> ok   : push "homelab recovered", priority default
ok -> ok     : no push
```

This is edge-triggered by design: one push when things break, one when they
recover, nothing in between even if the mini stays down for days.

## Practitioner steps (not done by this change)

These two steps are dashboard/CLI actions outside the Worker's code and are
left for the practitioner to complete before the alert path is live.

1. **Expose the status page through the tunnel.** Run
   `homelab public status status.<your public zone>` (uses the existing
   `tunnel-add-app.sh` tooling), then confirm from a non-tailnet network
   that `https://status.<zone>/status.json` returns the JSON above. The
   file carries only booleans and a timestamp, so no Access policy is
   needed. If exposing the hostname is undesirable, use an unguessable path
   instead. Once this is live, update `monitoring/worker/wrangler.toml`'s
   `STATUS_URL` to match (it currently points at
   `https://status.homelab.nate.green/status.json` as a placeholder).

2. **Add the Cloudflare Tunnel Health notification.** In the Cloudflare
   dashboard, under Notifications, add a "Cloudflare Tunnel Health Alert"
   if the free plan offers it. Deliver it as a webhook to
   `https://ntfy.sh/<topic>` (ntfy accepts a plain POST body as the
   message). If the free plan doesn't offer this notification, skip it —
   the Worker's staleness check covers the mini being off anyway, about 10
   minutes later.

## Deploying the Worker

From `monitoring/worker/`, one time:

```bash
npx wrangler login
npx wrangler kv namespace create STATE
# paste the returned id into wrangler.toml's kv_namespaces[0].id
npx wrangler secret put NTFY_TOPIC
npx wrangler deploy
```

Free-plan limits: Cron Triggers, 100k requests/day, KV 1k writes/day. This
Worker uses roughly 300 requests/day (one status fetch every 5 minutes) and
at most a handful of KV writes a day (only on state transitions).

## Proving it works

With the ntfy phone app subscribed to the topic:

```bash
ssh ng-mini docker stop pihole
```

Within about 10 minutes (one reconciler run writes `"dns": false`, then one
Worker tick reads it) a "homelab DOWN: red: dns" push should arrive. Then:

```bash
ssh ng-mini docker start pihole
```

A "homelab recovered" push should follow on the next tick. Record both
push timestamps as the proof this alerting path actually fires.
