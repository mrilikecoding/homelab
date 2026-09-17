# Monitoring: free alerting on Cloudflare

A Cloudflare Worker (`monitoring/worker/`) polls the homelab's public status
feed and pushes to a phone via the self-hosted ntfy when the mini goes stale or red. It
exists because a 2026-09-16 power loss went 11 hours with no alert: nothing
was watching the watcher.

## What it does

The mini's boot reconciler (`reconcile.sh`, runs every 10 minutes via
launchd) writes `status/html/status.json` with the shape:

```json
{"generated": "2026-09-17T20:05:28Z", "ok": true, "checks": {"colima": true, "doctor": true, "dns": true, "pihole_healthy": true, "apps": true, "serve": true}}
```

The Worker (`monitoring/worker/src/index.js`) runs on a Cron Trigger every 5
minutes, fetches that JSON over the public tunnel (`cache: "no-store"`), and
classifies the result as one of:

- `unreachable` — the fetch itself failed or timed out (10s)
- `http` — the response wasn't 2xx
- `nojson` — the body isn't valid JSON
- `stale` — `generated` is missing, unparseable, more than 15 minutes old, or
  more than a minute in the future (clock skew between the mini and the
  Worker)
- `red:<keys>` — `ok` is not `true`; the class and the alert message both
  name every check in `checks` whose value is not `true` (generic over
  whatever keys the reconciler adds), sorted for the class
- `ok` — fresh and green

A `doctor.sh --fix` run whose repairs all held now exits 0 (`check_fixed`
decrements the failure count), so `"doctor": true` even on a run that had to
fix something. A self-heal that succeeds no longer trips a false "homelab
DOWN" push.

## State machine

The Worker tracks the *class* from above, not a plain ok/down boolean. The
last class is stored in KV (`STATE["last"]`) so a push only fires when the
class changes:

```
ok            -> non-ok        : push "homelab DOWN: <reason>", priority high
non-ok        -> same non-ok   : no push (already alerted)
non-ok        -> different non-ok : push "homelab still DOWN: <reason>", priority high
non-ok        -> ok            : push "homelab recovered", priority default
ok            -> ok            : no push
```

Tracking the class means a lingering, low-severity red (say, a cert warning)
no longer hides a new failure: going from `red:cert` to `red:cert,dns` is a
class change and pushes "still DOWN: red: cert, dns", where the old ok/down
model would have stayed silent because both states were just "down".

This is still edge-triggered: one push when things break, one for each new
kind of break, one when things fully recover, nothing in between even if the
mini stays down for days.

A fresh-but-red status gets one tick of grace: the first red after ok is
held as `pending` in KV and not pushed; a red on the next tick (five
minutes later) pushes DOWN. This covers the reconciler's first pass after
a Colima start, which publishes `ok: false` once while pihole is in its
healthcheck window and Dokku recycles the apps. Stale, unreachable and
non-JSON verdicts have no grace: they mean the mini is gone.

## Practitioner steps (not done by this change)

These two steps are dashboard/CLI actions outside the Worker's code and are
left for the practitioner to complete before the alert path is live.

1. **Expose the status page through the tunnel.** First confirm the app name
   Dokku knows it by: `ssh ng-mini 'docker exec dokku dokku apps:exists
   status'` (`tunnel-add-app.sh` requires the app to already exist and fails
   without it). Then run `homelab public status status.<your public zone>`
   (the existing `tunnel-add-app.sh` tooling), and confirm from a
   non-tailnet network that `https://status.<zone>/status.json` returns the
   JSON above.

   Making the `status` app public exposes its *whole* hostname, not only
   `status.json`. `index.html` is the Dokku app inventory
   (`status/generate-status.sh`, refreshed every 60 seconds) — every app
   name and whether it's running or stopped. Pick one:

   - A Cloudflare Access policy on the hostname, with a bypass rule for
     `/status.json` so the Worker's unauthenticated fetch keeps working
     while everything else requires a login.
   - Serve the JSON at an unguessable path instead of putting a public
     hostname on the `status` app at all.

   Once this is live, update `monitoring/worker/wrangler.toml`'s
   `STATUS_URL` to match (it currently points at
   `https://status.homelab.nate.green/status.json` as a placeholder).

2. **Add the Cloudflare Tunnel Health notification.** In the Cloudflare
   dashboard, under Notifications, add a "Cloudflare Tunnel Health Alert"
   if the free plan offers it. Deliver it as a webhook to
   `https://the self-hosted ntfy/<topic>` (ntfy accepts a plain POST body as the
   message). If the free plan doesn't offer this notification, skip it —
   the Worker's staleness check covers the mini being off anyway, about 10
   minutes later.

## Deploying the Worker

From `monitoring/worker/`, one time:

```bash
npx wrangler login
npx wrangler kv namespace create STATE
# paste the returned id into wrangler.toml's kv_namespaces[0].id
openssl rand -hex 16
npx wrangler secret put NTFY_TOPIC   # paste the hex string above as the topic
npx wrangler deploy
```

the self-hosted ntfy topics are public unless reserved (a paid feature): anyone who
learns the topic name can read the alerts and post fake ones to it. That's
why the topic is generated randomly rather than a memorable word, and kept
out of the repo — it lives only as this wrangler secret.

Free-plan limits: Cron Triggers, 100k requests/day, KV 1k writes/day. This
Worker uses roughly 300 requests/day (one status fetch every 5 minutes) and
at most a handful of KV writes a day (only on state transitions).

## Proving it works

With the ntfy phone app subscribed to the topic, stop something the doctor
cannot repair — the llm-orc serve isn't one of `doctor.sh`'s checks, so
nothing brings it back until you do:

```bash
ssh ng-mini 'launchctl bootout gui/$(id -u)/com.llm-orc.serve'
```

Within about 10 minutes (one reconciler run writes `"serve": false`, then
one Worker tick reads it) a "homelab DOWN: red: serve" push should arrive.
Then:

```bash
ssh ng-mini 'launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.llm-orc.serve.plist'
```

A "homelab recovered" push should follow on the next tick. Record both
push timestamps as the proof this alerting path actually fires.

`docker stop pihole` is not a valid proof: doctor's check 7 restarts a
stopped container inside the same `--fix` run, so the reconciler heals it
before any Worker tick ever observes it down.

## ntfy is self-hosted on the mini

ntfy runs as the Dokku app `ntfy` (image `binwiederhier/ntfy`, start
command `serve`, data in `/var/lib/dokku/data/storage/ntfy`), tailnet
`https://ntfy.homelab.nate.green`, public `https://ntfy.nate.green`
through the tunnel. Auth is `deny-all` by default: user `homelab-monitor`
has write-only access to topic `homelab` (the Worker holds one of its
tokens as the secret `NTFY_TOKEN`); user `nathan` has read-only access
(the phone subscribes as that user). Anonymous can neither read nor
publish. Manage with `docker exec ntfy.web.1 ntfy user|access|token ...`.

Why not ntfy.sh: its anonymous quota is per source IP, and a Cloudflare
Worker shares its egress IP with every other Worker, so pushes were
refused with 429 "daily message quota reached" on 2026-09-17.

The trade: pushes about the mini only leave while the mini is up. A partial
outage (serve down, DNS dead, a container gone) is the class this covers.
For the mini being fully off, enable Cloudflare's Tunnel Health
notification (email, free); the Worker's staleness check has nothing to
deliver to in that case.
