# Outage resilience: reconcile at boot, truthful health, external alerting

> **For agentic workers:** use superpowers:subagent-driven-development (one fresh
> subagent per work package, review between packages) or superpowers:executing-plans.
> Steps use `- [ ]` checkboxes.

**Goal:** after a power loss the mini brings the homelab back without a human,
health checks say the truth, and a phone gets a push within minutes when they don't.

**Architecture:** one launchd reconciler on the mini (unlock Lima's disk, start
Colima, run `doctor.sh --fix`, ping a heartbeat) replaces two racing autostart
units; pihole gets a real DNS healthcheck and binds only the interface the socat
forwarder talks to; Uptime Kuma plus ntfy on a small VPS joined to the tailnet
watch DNS, the apps, the llm-orc serve, and the heartbeat.

**Tech:** bash + launchd (mini), Docker healthcheck, Pi-hole v6 `pihole-FTL --config`,
Uptime Kuma 2.x, ntfy, Tailscale. No new languages.

**Spec:** the incident and its diagnosis are in the practitioner's llm-orc session
memory (`reference-ng-mini-reboot-recovery`) and summarized in
`docs/diagnostics.md` (WP1 adds the section). Decisions made 2026-09-17:
pihole stays the tailnet-wide resolver by design; the mini stays the single
point of entry; a UPS is optional because the mini auto-reboots.

## Global constraints

- Everything on the mini runs as `nathanielgreen`, gui launchd domain (console
  is logged in; `caffeinate` holds sleep off). Non-login shells lack
  `/usr/local/bin` on PATH: absolute paths in every plist and ssh command.
- Colima is started with `--network-address` (VM at `192.168.64.2`, interface
  `col0` inside the VM). The socat forwarder (`com.pihole.dns`, system domain)
  sends `100.92.166.102:53 -> 192.168.64.2:53`.
- `doctor.sh` is the reconciler's brain; new checks go there, not in new scripts.
  It is idempotent and takes `--fix`.
- Kuma and ntfy must run OFF the mini and ON the tailnet (the DNS check is a
  query to `100.92.166.102`; a monitor that resolves names cannot see the failure).
- Nothing here changes pihole's role or the Tailscale DNS config.
- Spend (VPS) and pushes to `mrilikecoding/homelab` need the practitioner's go.

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

**Produces:** `reconcile.sh` exit 0 when the verification set passes locally;
`HEARTBEAT_URL` (optional env in the plist) pinged on success (WP4 consumes).

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
if "$SCRIPT_DIR/doctor.sh" --fix; then
  log "doctor: all checks pass"
  [[ -n "${HEARTBEAT_URL:-}" ]] && curl -fsS -m 10 "$HEARTBEAT_URL" >/dev/null && log "heartbeat sent"
  exit 0
fi
log "doctor: checks failing"
exit 1
```

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
    <key>HEARTBEAT_URL</key><string></string>
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
  (the exact stale lock from 2026-09-16), run it: exit 0. Record all three
  outputs in the PR.

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

### WP4: Uptime Kuma + ntfy on a VPS, joined to the tailnet

**Owner:** practitioner for the VPS and the Tailscale auth key (spend + admin);
an agent for everything after ssh works. **Gate:** WP0 decisions below.

**WP0 decisions (practitioner, before WP4 starts):**
1. Where it runs: a small VPS (DigitalOcean/AWS CLIs are installed on the
   laptop; ~$5/month, 1 GB is enough) or a Pi on the LAN. Either must join the tailnet.
2. ntfy: self-hosted on the same box (private topics, recommended) or `ntfy.sh`.
3. Kuma exposure: tailnet-only. `tailscale serve` on the VPS gives HTTPS at
   `https://<vps>.corgi-woodpecker.ts.net` with no public port.

- [ ] **Step 1 (practitioner): VPS up, `tailscale up`, Docker installed, ssh key for the agent.**
- [ ] **Step 2: compose.** `monitoring/docker-compose.yml` in this repo:

```yaml
services:
  kuma:
    image: louislam/uptime-kuma:2
    restart: unless-stopped
    volumes: [kuma-data:/app/data]
    ports: ["127.0.0.1:3001:3001"]
  ntfy:
    image: binwiederhier/ntfy
    restart: unless-stopped
    command: serve
    volumes: [ntfy-cache:/var/cache/ntfy]
    ports: ["127.0.0.1:8090:80"]
volumes: { kuma-data: {}, ntfy-cache: {} }
```

  Then on the VPS: `tailscale serve --bg --https=443 http://127.0.0.1:3001` and
  `tailscale serve --bg --https=8443 http://127.0.0.1:8090` (Kuma and ntfy over
  the tailnet only). Record both URLs in `docs/monitoring.md`.

- [ ] **Step 3: monitors** (Kuma UI; this is configuration, document it in
  `docs/monitoring.md` as a table and export Kuma's backup JSON into
  `monitoring/kuma-backup.json` if 2.x still offers it):

| name | type | target | expect | interval |
| --- | --- | --- | --- | --- |
| dns via mini | DNS | `llm-orc.homelab.nate.green` @ `100.92.166.102` A | `100.92.166.102` | 60 s |
| status app | HTTP keyword | `https://status.homelab.nate.green/` | `Homelab Status` | 60 s |
| trellis | HTTP | `https://trellis.homelab.nate.green/` | 200 | 60 s |
| llm-orc serve | HTTP keyword | `https://llm-orc.homelab.nate.green/health` | `healthy` | 60 s |
| llm-orc router | HTTP keyword | `https://llm-orc.homelab.nate.green/api/models` | `"models"` | 120 s |
| mini reconciler | Push | (Kuma-generated URL) | heartbeat every 15 min, 20 min grace | |

  Retries 2 before alerting; one notification channel: ntfy topic `homelab`,
  attached to every monitor, "send on down and on recovery".

- [ ] **Step 4: wire the heartbeat.** Put the push URL from Kuma into
  `HEARTBEAT_URL` in `~/Library/LaunchAgents/com.homelab.reconcile.plist` on the
  mini, `launchctl bootout` + `bootstrap` (a `kickstart` keeps the old plist).
  Confirm Kuma shows the push monitor up within 10 minutes.
- [ ] **Step 5: phone.** Install the ntfy app, subscribe to the `homelab` topic
  on the self-hosted server. Test: pause the "trellis" monitor's target
  (`ssh ng-mini docker stop trellis.web.1`, then `docker start`) and confirm a
  down and a recovery push arrive. Commit: `feat: uptime kuma + ntfy monitoring stack`.

---

### WP5 (optional, llm-orc repo): readiness in `/health`

`GET /health` on the serve is liveness only (`{"status":"healthy","version":...}`
with no router and no model). Kuma covers readiness via `/api/models` (WP4).
If wanted anyway: file an llm-orc issue for a `ready` boolean plus `router`
reachability in `/health`, TDD against the stub router, never loading a model
to answer. Not needed for this plan.

---

### WP6: retire the generated status page

After WP4's Kuma status page exists (Kuma: Status Pages, add the six monitors,
tailnet URL): `launchctl bootout gui/$(id -u)/com.homelab.status-refresh`, remove
the plist, and either delete the `status` Dokku app or keep it as a redirect.
Practitioner's call; one commit either way.

---

### WP7: the plug-pull

**Owner:** practitioner, after WP1, WP2, WP4 are live (WP3 optional).

- [ ] Note the time. Pull the mini's power. Plug it back in.
- [ ] Expected: Kuma pushes "dns via mini DOWN" and the app monitors within
  2 minutes; the mini reboots and auto-logs-in; `com.homelab.reconcile` runs at
  load, unlocks the disk, starts Colima, doctor fixes dnsmasq/pihole; every
  monitor recovers within about 6 minutes of power returning; the heartbeat
  arrives; no human touched anything.
- [ ] Record the actual timeline in `docs/diagnostics.md` under "After a reboot".
  Anything that needed a hand is a new WP, not a note.

## Order and delegation

WP1 and WP2 are independent and both Sonnet-class implementers (repo edits +
tests on the mini over ssh; the deploy steps are applied by the lead or the
practitioner). WP3 starts with its spike and can run in parallel. WP4 waits on
WP0. WP7 last. Each WP is one PR to `mrilikecoding/homelab`; pushes are gated.

## Stop points (do not plan past these)

- WP3's spike decides whether the source fix ships or the reconciler's pkill is
  the permanent answer.
- WP0 decides the VPS; the compose and monitor table are written to survive
  either host choice.
- Kuma 2.x's backup export may be gone; if so the monitor table in
  `docs/monitoring.md` is the record and the step says so.
