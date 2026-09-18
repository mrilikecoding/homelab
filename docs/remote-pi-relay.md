# Remote Pi relay

A self-hosted relay for [Remote Pi](https://github.com/jacobaraujo7/remote_pi),
the phone client for the Pi coding agent. The relay routes WebSocket frames
between the phone app and `pi-extension` processes on desktops. It runs on
the mini because the upstream project's shared relay can read every message
it forwards (TLS in transit, not end to end); with our own relay the only
thing traffic touches is the tailnet.

## What runs

Dokku app `remote-pi-relay` on the mini, image
`jacobmoura7/remote-pi-relay:v0.3.1` (pinned; `latest` was the same digest
on 2026-09-18). One port, 3000, serves three things: `GET /` (WebSocket
upgrade), `GET /health`, and `GET|POST /mesh/<owner_pk_hash>` (Owner-signed
peer lists so a phone restored from iCloud Keychain can recover its peers).
Config: `RUST_LOG=info`, `ports:set http:80:3000`, the homelab wildcard
cert. Storage: `/var/lib/dokku/data/storage/remote-pi-relay` mounted at
`/data`, holding `mesh.db` (SQLite, membership metadata only, never message
bodies). Same volume arrangement as ntfy, so it survives `dokku` rebuilds
and Colima restarts. If it is ever lost, clients re-publish their peer lists
at their next change.

Tailnet only: `wss://remote-pi-relay.homelab.nate.green`. Not on the
Cloudflare tunnel; the phone needs Tailscale up, which it already does for
ntfy. Add `homelab public remote-pi-relay <hostname>` if that changes.

## Client side

On any machine running Pi:

```bash
pi install npm:remote-pi
```

then `/remote-pi` in the Pi chat, choose a custom relay, enter
`wss://remote-pi-relay.homelab.nate.green`, scan the QR with the phone app.

## Checking it

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://remote-pi-relay.homelab.nate.green/health   # 200
curl -s -i --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  https://remote-pi-relay.homelab.nate.green/ | head -1                                       # HTTP/1.1 101
```

`--http1.1` matters: curl defaults to HTTP/2 against nginx, and HTTP/2 has
no `Upgrade`, so the relay sees a plain GET and drops the socket (nginx then
reports 502). The container also has its own Docker HEALTHCHECK on
`/health`, visible in `docker ps`.

## Upgrading

```bash
docker exec dokku dokku git:from-image remote-pi-relay jacobmoura7/remote-pi-relay:<tag>
```

Pick the tag by image date, not by number: the project renumbered, so the
`v1.0.x` tags on Docker Hub are from May 2026 and predate the mesh feature
(separate health port 3001, no `/mesh`, no `/data`), while `v0.3.x` is the
current line. Deploying `v1.0.1` first was how this was learned. The relay
README says to roll the relay before the extension when they change wire
labels.
