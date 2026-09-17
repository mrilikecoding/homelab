# Outage resilience: follow-ups after the 2026-09-17 merge

Left open on purpose when `plan/outage-resilience` merged (final review
findings 7, 10, 12, 13 and the deferred items). None blocks the plug-pull.

- `doctor.sh` check 3's fix kickstarts `system/com.homelab.dns`; the loaded
  daemon on the mini is `com.pihole.dns`. Same class as the check 2 fix
  that shipped; human-run only (needs sudo).
- `doctor.sh`: a check whose fix runs but does not resolve calls
  `check_fail` twice (checks 1, 3, 4, 5, 7, 10), so the "N failed" summary
  can overcount by one per such check. Cosmetic.
- `doctor.sh` check 6 passed while FTL was frozen (Task 2 test); find out
  what answered `dig @<tailscale ip>` in that state (Lima's dnsmasq, or a
  cached answer) and make the check ask pihole specifically, like check 8.
- `install.sh` still installs `com.homelab.startup` (a Colima starter with
  no disk unlock) and does not install `launchd/com.homelab.reconcile.plist`
  or remove the brew Colima service; a rebuild from `install.sh` brings the
  boot race back. Fold the reconciler into `install.sh`.
- `monitoring/worker`: pin `wrangler` as a devDependency (asks-first: new
  dependency); add a test for the fetch-timeout message; note in the deploy
  step that the first tick after a redeploy over old `"down"` KV state may
  push one redundant "still DOWN".
- Reconciler log (`~/Library/Logs/homelab-reconcile.log`) has no rotation
  (~100 KB/day): a `newsyslog` entry or a size cap in `reconcile.sh`.
- `.superpowers/sdd/2026-09-17-outage-resilience/` (session workspace,
  git-ignored) held the per-task reports with the live test transcripts;
  the plan, `docs/diagnostics.md` and this file carry what matters from
  them.
- Ollama is still installed on the mini (brew service on 11434); nothing
  uses it since llm-orc 0.20.0. Practitioner's call to remove.
- The status page is two containers: the Dokku app `status` (a proxy) and
  `homelab-status` (nginx on :5000 from `status/docker-compose.yml`, restart
  policy `unless-stopped`). Docker does not restart an `unless-stopped`
  container after the daemon itself stopped it, so `homelab-status` stays
  down after every Colima stop and nothing checks it (found 2026-09-17: down
  for an hour after test (c); the public hostname answered 502). Add it to
  the reconciler's `apps` probe and to doctor check 7, or give it
  `restart: always`, or fold it into the Dokku app.
