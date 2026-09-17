# Outage resilience: reconcile at boot, truthful health, external alerting

> **For agentic workers:** use superpowers:subagent-driven-development (one fresh
> subagent per work package, review between packages) or superpowers:executing-plans.
> Steps use `- [ ]` checkboxes.

**Goal:** after a power loss the mini brings the homelab back without a human,
health checks say the truth, and a phone gets a push within minutes when they don't.

**Architecture:** one launchd reconciler on the mini (unlock Lima's disk, start
Colima, run `doctor.sh --fix`, ping a heartbeat) replaces two racing autostart
units and publishes a `status.json` of real probes; pihole gets a real DNS
healthcheck and binds only the interface the socat forwarder talks to; a
Cloudflare Cron Trigger Worker (free plan) reads that status through the tunnel
and pushes to ntfy.sh when it is stale or red, and Cloudflare's tunnel health
notification covers the mini being off entirely. No paid infrastructure.

**Tech:** bash + launchd (mini), Docker healthcheck, Pi-hole v6 `pihole-FTL --config`,
Cloudflare Workers (Cron Triggers + KV, free plan), ntfy.sh. No paid services.

**Spec:** the incident and its diagnosis are in the practitioner's llm-orc session
memory (`reference-ng-mini-reboot-recovery`) and summarized in
`docs/diagnostics.md` (WP1 adds the section). Decisions made 2026-09-17:
pihole stays the tailnet-wide resolver by design; the mini stays the single
point of entry; a UPS is optional because the mini auto-reboots; no paid
infrastructure for monitoring (no VPS); alerting rides Cloudflare's free plan
and ntfy.sh, and a self-hosted ntfy on the mini is for non-outage notifications.

## Global constraints

- Everything on the mini runs as `nathanielgreen`, gui launchd domain (console
  is logged in; `caffeinate` holds sleep off). Non-login shells lack
  `/usr/local/bin` on PATH: absolute paths in every plist and ssh command.
- Colima is started with `--network-address` (VM at `192.168.64.2`, interface
  `col0` inside the VM). The socat forwarder (`com.pihole.dns`, system domain)
  sends `100.92.166.102:53 -> 192.168.64.2:53`.
- `doctor.sh` is the reconciler's brain; new checks go there, not in new scripts.
  It is idempotent and takes `--fix`.
- The alerting path must not depend on the mini: it runs on Cloudflare's free
  plan and posts to `ntfy.sh` (a self-hosted ntfy would die with the mini).
  Nothing is paid; if a Cloudflare feature turns out not to be free, stop and say so.
- The Worker cannot join the tailnet, so DNS truth is measured ON the mini
  (a local query against pihole) and published; the Worker checks the
  publication is fresh and green.
- Nothing here changes pihole's role or the Tailscale DNS config.
- Pushes to `mrilikecoding/homelab` need the practitioner's go.

## Verification set (used by WP1, WP4, WP7)

From a tailnet device that is not the mini:

    dig +time=3 +tries=1 @100.92.166.102 llm-orc.homelab.nate.green +short   # 100.92.166.102
    curl -s https://status.homelab.nate.green/ -o /dev/null -w '%{http_code}'  # 200
    curl -s https://llm-orc.homelab.nate.green/health                          # {"status":"healthy",...}
    curl -s https://llm-orc.homelab.nate.green/api/models                      # router reachable; list of models

---

### WP1: boot reconciler on the mini

**Owner:** implementer (edits the repo); applying on the mini is a deploy step.

**Files:**
- Create: `reconcile.sh` (repo root, beside `doctor.sh`)
- Create: `launchd/com.homelab.reconcile.plist`
- Modify: `doctor.sh:84-120` (check 1: add the disk unlock before the Colima restart)
- Modify: `docs/diagnostics.md` (new section "After a reboot")
- Remove from the mini (not from the repo): `~/Library/LaunchAgents/com.colima.start.plist`; `brew services stop colima`

**Produces:** `reconcile.sh` exit 0 when the verification set passes locally,
and `status/html/status.json` rewritten on EVERY run (pass or fail) with the
shape WP4 consumes:

```json
{"generated": "2026-09-17T08:30:00-07:00", "ok": true,
 "checks": {"colima": true, "dns": true, "pihole_healthy": true, "apps": true, "serve": true}}
```

`dns` is a local `dig +time=2 +tries=1 @127.0.0.1 pi.hole` on the mini (through
the socat forwarder use `@100.92.166.102`), `serve` is `curl 127.0.0.1:8765/api/models`
returning JSON, `apps` is doctor's container check, `pihole_healthy` is the
Docker health status from WP2 (`true` until WP2 lands).

- [ ] **Step 1: `reconcile.sh`**

```bash
#!/usr/bin/env bash
# Bring the homelab up after a reboot or a power loss. Idempotent; safe to run
# every 10 minutes. Exit 0 only when doctor.sh passes.
set -uo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LIMA_HOME="$HOME/.colima/_lima"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "$(date '+%F %T') $*"; }

# 1. Colima. A stale disk lock survives an unclean shutdown and blocks boot.
if ! colima status >/dev/null 2>&1; then
  if [[ -L "$LIMA_HOME/_disks/colima/in_use_by" ]] && ! pgrep -qf 'limactl.*hostagent'; then
    log "colima stopped with a stale disk lock; unlocking"
    limactl disk unlock colima
  fi
  log "starting colima"
  colima stop >/dev/null 2>&1 || true
  colima start --network-address || { log "colima start failed"; exit 1; }
fi
# Docker must answer before doctor.sh can inspect containers.
for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done

# 2. Everything else is doctor.sh's job (dnsmasq on :53, listening mode, certs,
#    containers, DNS answering). --fix applies its known repairs.
doctor_ok=false
"$SCRIPT_DIR/doctor.sh" --fix && doctor_ok=true

# 3. Publish what is true right now. WP4's Worker reads this through the tunnel.
dns_ok=false;    dig +time=2 +tries=1 @100.92.166.102 pi.hole +short 2>/dev/null | grep -q . && dns_ok=true
serve_ok=false;  curl -fsS -m 5 http://127.0.0.1:8765/api/models 2>/dev/null | grep -q '"models"' && serve_ok=true
colima_ok=false; colima status >/dev/null 2>&1 && colima_ok=true
ph=$(docker inspect --format '{{.State.Health.Status}}' pihole 2>/dev/null); pihole_ok=false; [[ "$ph" == "healthy" || -z "$ph" ]] && pihole_ok=true
all_ok=false; [[ $doctor_ok == true && $dns_ok == true && $serve_ok == true && $colima_ok == true && $pihole_ok == true ]] && all_ok=true
mkdir -p "$SCRIPT_DIR/status/html"
printf '{"generated":"%s","ok":%s,"checks":{"colima":%s,"dns":%s,"pihole_healthy":%s,"apps":%s,"serve":%s}}\n' \
  "$(date +%FT%T%z)" "$all_ok" "$colima_ok" "$dns_ok" "$pihole_ok" "$doctor_ok" "$serve_ok" \
  > "$SCRIPT_DIR/status/html/status.json.tmp" && mv "$SCRIPT_DIR/status/html/status.json.tmp" "$SCRIPT_DIR/status/html/status.json"

if [[ $all_ok == true ]]; then log "all checks pass"; exit 0; fi
log "checks failing: doctor=$doctor_ok dns=$dns_ok serve=$serve_ok colima=$colima_ok pihole=$pihole_ok"
exit 1
```

  `status/html/` is what the `status` Dokku app serves (see
  `status/generate-status.sh`), so `status.json` appears next to `index.html`
  at `https://status.homelab.nate.green/status.json` with no other change.

- [ ] **Step 2: `doctor.sh` check 1 learns the disk lock.** In `run_server_checks`,
  check 1 (line ~95) restarts Colima when the VM has no IP. Before the
  `colima stop; colima start --network-address` in its `try_fix`, insert:
  `LIMA_HOME=$HOME/.colima/_lima limactl disk unlock colima 2>/dev/null || true`.
  (Unlock is a no-op when the disk is not locked; when the VM is stopped the
  lock is always stale.)

- [ ] **Step 3: the plist** (`launchd/com.homelab.reconcile.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.homelab.reconcile</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>/Users/nathanielgreen/homelab/reconcile.sh</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>600</integer>
  <key>StandardOutPath</key><string>/Users/nathanielgreen/Library/Logs/homelab-reconcile.log</string>
  <key>StandardErrorPath</key><string>/Users/nathanielgreen/Library/Logs/homelab-reconcile.log</string>
</dict></plist>
```

- [ ] **Step 4: tests, on the mini, in this order.** (a) Run `reconcile.sh` twice
  on a healthy system: both exit 0, second run changes nothing (idempotence is
  the test). (b) `colima stop`, run it: exit 0 and the verification set passes
  from the laptop. (c) `colima stop`, then recreate the failure:
  `ln -sfn ~/.colima/_lima/colima ~/.colima/_lima/_disks/colima/in_use_by`
  (the exact stale lock from 2026-09-16), run it: exit 0. (d) With everything
  healthy, `docker stop pihole`, run it: exit 1 and `status.json` says
  `"dns": false`; `docker start pihole`, run it: exit 0 and `"dns": true`.
  Record all four outputs in the PR.

- [ ] **Step 5: deploy.** `cp launchd/com.homelab.reconcile.plist ~/Library/LaunchAgents/`,
  `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.homelab.reconcile.plist`;
  `launchctl bootout gui/$(id -u)/com.colima.start; rm ~/Library/LaunchAgents/com.colima.start.plist`;
  `brew services stop colima` (its unit has sat in `error 1` since the reboot).
  Then `launchctl print gui/$(id -u)/com.homelab.reconcile | grep -E 'state|last exit'`.

- [ ] **Step 6: docs + commit.** `docs/diagnostics.md` gains "After a reboot":
  what comes back alone (llm-orc serve, ollama, tunnel), what the reconciler
  does, where its log is. Commit: `feat: boot reconciler replaces the two colima autostart units`.

---

### WP2: pihole reports the truth

**Owner:** implementer; the container re-create is a deploy step (30 s of DNS downtime).

**Files:**
- Modify: `install.sh:80-91` (the `docker run` for pihole)
- Modify: `doctor.sh` (new check after check 7: pihole container health)

- [ ] **Step 1: healthcheck on the container.** Add to the `docker run` in `install.sh`:

```
  --health-cmd 'dig +time=2 +tries=1 @127.0.0.1 pi.hole >/dev/null || exit 1' \
  --health-interval 30s --health-timeout 5s --health-retries 3 \
```

  (The image's default check tests the web server, which is why the container
  read "healthy" for 11 hours with DNS dead on 2026-09-16.)

- [ ] **Step 2: doctor check "pihole healthy".** After check 7 in
  `run_server_checks`: read `docker inspect --format '{{.State.Health.Status}}' pihole`;
  `healthy` passes; anything else fails, and the fix is
  `colima ssh -- sudo pkill dnsmasq; docker restart pihole` (the same repair as
  check 5, because that is the only cause seen so far). Bump `TOTAL`.

- [ ] **Step 3: re-create the container on the mini** with the new flags
  (config lives in the bind mounts, nothing is lost): run the `docker rm -f pihole`
  + `docker run` block from `install.sh` with the mini's `.env` values. Confirm
  `docker inspect --format '{{.State.Health.Status}}' pihole` is `healthy` and the
  verification set passes.

- [ ] **Step 4: show the guard going red.** `docker exec pihole pkill -STOP pihole-FTL`
  (or `kill -STOP $(pidof pihole-FTL)` if the image lacks pkill), wait 100 s, `docker inspect` must say `unhealthy`; `docker exec pihole pkill -CONT pihole-FTL`,
  wait, `healthy` again. Then `doctor.sh` (no `--fix`) with FTL stopped must FAIL
  the new check. Paste both in the PR. Commit: `feat: pihole healthcheck tests DNS, not the web server`.

---

### WP3: dnsmasq collision fixed at the source (spike first)

**Owner:** implementer, after a 15-minute spike. **Gate:** the spike result.

Every Colima start leaves Lima's dnsmasq on `127.0.0.1:53` and `192.168.5.1:53`
inside the VM; pihole (`listeningMode = ALL`) then fails to bind and runs with
DNS dead. WP1's reconciler papers over it with `pkill dnsmasq`. The source fix:
pihole binds only `col0` (`192.168.64.2`), which is all the forwarder needs.

- [ ] **Spike, on the mini:**
  `docker exec pihole pihole-FTL --config dns.interface col0` and
  `docker exec pihole pihole-FTL --config dns.listeningMode BIND`, then
  `colima restart` (this is the exact failure path). Expected: no
  `CRIT ... Address in use` in `docker logs pihole`, and the verification set
  passes without anyone killing dnsmasq. If `col0` is not stable across
  restarts or BIND misbehaves, revert both settings to `ALL` and stop; the
  reconciler's pkill stays the fix and this WP closes as "not viable, why".
- [ ] **If green:** `doctor.sh:183-206` check 4 currently insists on `ALL`;
  change it to accept `BIND` when `dns.interface` is `col0` (and keep fixing
  anything else to that pair). Add both `--config` lines to `install.sh` after
  the existing port sed. Commit: `fix: pihole binds only col0, so Lima's dnsmasq cannot take port 53`.

---

### WP4: free alerting on Cloudflare: tunnel health notification + a Cron Worker

**Owner:** an agent for the Worker and its tests; the practitioner for the two
Cloudflare dashboard steps (notification, public hostname) and for choosing the
ntfy topic. **Gate:** WP1 (the Worker reads WP1's `status.json`).

**Files:**
- Create: `monitoring/worker/src/index.js`, `monitoring/worker/wrangler.toml`,
  `monitoring/worker/test/index.test.js` (vitest; `npm create cloudflare` gives the scaffold)
- Modify: `docs/monitoring.md` (new; the two dashboard steps, the topic, the URLs)

**Produces:** a push on the `ntfy.sh` topic when the mini's status is
unreachable, stale, or red; one push on recovery; nothing in between.

- [ ] **Step 1 (practitioner): expose the status page through the tunnel.**
  `homelab public status status.<your public zone>` (the existing tunnel
  tooling; `tunnel-add-app.sh`). Confirm from a non-tailnet network that
  `https://status.<zone>/status.json` returns WP1's JSON. It carries only
  booleans and a timestamp; no Access policy needed. If you would rather not
  expose the page, put it at an unguessable path instead.

- [ ] **Step 2 (practitioner): tunnel health notification.** Cloudflare
  dashboard, Notifications, add "Cloudflare Tunnel Health Alert" (verify it is
  offered on the free plan; if not, skip: Step 4's staleness check covers the
  mini being off, ~10 min later). Delivery: webhook to
  `https://ntfy.sh/<topic>` (ntfy accepts a plain POST body as the message).

- [ ] **Step 3: the Worker.** Cron every 5 minutes; KV namespace `STATE`
  (free) holds the last verdict so alerts are edge-triggered.

```js
// monitoring/worker/src/index.js
const STALE_MS = 15 * 60 * 1000;

export async function evaluate(res, now) {
  if (!res.ok) return { ok: false, why: `status.json ${res.status}` };
  const body = await res.json();
  const age = now - Date.parse(body.generated);
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
      await fetch(`https://ntfy.sh/${env.NTFY_TOPIC}`, {
        method: "POST",
        headers: { Title: title, Priority: verdict.ok ? "default" : "high", Tags: verdict.ok ? "white_check_mark" : "rotating_light" },
        body: `${verdict.why} (${new Date().toISOString()})`,
      });
      await env.STATE.put("last", nowState);
    }
  },
};
```

```toml
# monitoring/worker/wrangler.toml
name = "homelab-monitor"
main = "src/index.js"
compatibility_date = "2026-09-01"
[triggers]
crons = ["*/5 * * * *"]
[[kv_namespaces]]
binding = "STATE"
id = "<created by: wrangler kv namespace create STATE>"
[vars]
STATUS_URL = "https://status.<zone>/status.json"
# NTFY_TOPIC is a secret: wrangler secret put NTFY_TOPIC
```

- [ ] **Step 4: tests first** (`test/index.test.js`, vitest, pure functions, no
  network): `evaluate` returns not-ok for a non-200 response; not-ok with
  `stale` for `generated` 16 minutes old; not-ok naming the red check for
  `{"ok":false,"checks":{"dns":false,...}}`; ok for a fresh green body. Then
  one test of `scheduled` with a fake `env` (`STATE` as a Map wrapper, `fetch`
  stubbed) proving: down after ok posts exactly one ntfy call; down after down
  posts none; ok after down posts the recovery. Run: `npx vitest run`.

- [ ] **Step 5: deploy.** `npx wrangler login` (practitioner, one time),
  `npx wrangler kv namespace create STATE` (paste the id), `npx wrangler secret put NTFY_TOPIC`,
  `npx wrangler deploy`. Free-plan limits: Cron Triggers, 100k requests/day,
  KV 1k writes/day; this uses ~300 requests and at most a handful of writes a day.

- [ ] **Step 6: prove it.** Phone: ntfy app subscribed to the topic. Then
  `ssh ng-mini docker stop pihole`; within ~10 minutes (one reconcile run
  writes `"dns": false`, one Worker tick reads it) a "homelab DOWN: red: dns"
  push arrives; `docker start pihole`; a "recovered" push follows. Paste both
  timestamps in the PR. Commit: `feat: cloudflare cron worker alerts to ntfy on stale or red status`.

---

### WP5 (optional, llm-orc repo): readiness in `/health`

`GET /health` on the serve is liveness only (`{"status":"healthy","version":...}`
with no router and no model). WP1's `serve` probe covers readiness via `/api/models`.
If wanted anyway: file an llm-orc issue for a `ready` boolean plus `router`
reachability in `/health`, TDD against the stub router, never loading a model
to answer. Not needed for this plan.

---

### WP6: (removed)

The generated status page stays: it is the transport for `status.json`.

---

### WP7: the plug-pull

**Owner:** practitioner, after WP1, WP2, WP4 are live (WP3 optional).

- [ ] Note the time. Pull the mini's power. Plug it back in.
- [ ] Expected: the tunnel health notification (if enabled) pushes within a
  couple of minutes; otherwise the Worker's staleness check pushes "homelab
  DOWN: unreachable" within ~10 minutes; the mini reboots and auto-logs-in;
  `com.homelab.reconcile` runs at load, unlocks the disk, starts Colima, doctor
  fixes dnsmasq/pihole, `status.json` goes green; the Worker pushes "recovered"
  on its next tick; no human touched anything.
- [ ] Record the actual timeline in `docs/diagnostics.md` under "After a reboot".
  Anything that needed a hand is a new WP, not a note.

## Order and delegation

WP1 and WP2 are independent and both Sonnet-class implementers (repo edits +
tests on the mini over ssh; the deploy steps are applied by the lead or the
practitioner). WP3 starts with its spike and can run in parallel. WP4 waits on
WP1 (its `status.json`) and on the practitioner's two dashboard steps. WP7
last. Each WP is one PR to `mrilikecoding/homelab`; pushes are gated.

## Stop points (do not plan past these)

- WP3's spike decides whether the source fix ships or the reconciler's pkill is
  the permanent answer.
- Whether "Cloudflare Tunnel Health Alert" is on the free plan: if not, the
  Worker's staleness check is the only "mini is off" signal (about 10 minutes
  slower) and the plan says so in `docs/monitoring.md`.
- Whether the status page may be public: if not, an unguessable path, decided
  by the practitioner at WP4 step 1.
