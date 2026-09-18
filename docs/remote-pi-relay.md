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

Tailnet only, at `https://remote-pi-relay.homelab.nate.green`. Give the
extension and the phone app that `https://` form; both reject `wss://` and
upgrade to WebSocket themselves. Not on the Cloudflare tunnel; the phone
needs Tailscale up, which it already does for ntfy. Add
`homelab public remote-pi-relay <hostname>` if that changes.

## Clients

Mesh membership is automatic: pairing the phone with a PC adds that PC's
Pi key to the phone's Owner-signed member list, which the app publishes to
`/mesh` on this relay. Two PCs paired with the same phone against the same
relay can reach each other (`/remote-pi peers` shows the other PC). Set the
app's relay URL (preferences) to the address above before pairing.

**Laptop.** Pi from nvm (Node 22), `pi install npm:remote-pi`;
`~/.pi/remote/config.json` holds `{"relay": "<address above>"}`. Global Pi
config (`settings.json`, `models.json`, the llm-orc bridge extension) lives
in dotfiles under `home/.pi/agent/`. Pair with `/remote-pi` then
`/remote-pi pair` in an interactive `pi`.

**Mini (daemon).** Set up 2026-09-18: nvm Node 22 (now the nvm default),
`npm i -g @earendil-works/pi-coding-agent remote-pi`, supervisor via
`remote-pi install` (LaunchAgent `dev.remotepi.supervisord`, log
`~/.pi/remote/supervisord.log`), one daemon `mini` in `~/agents/mini`. Pi's
default model there is the local serve over loopback
(`~/.pi/agent/models.json` -> `http://127.0.0.1:8765/v1`); the llm-orc
bridge reads `LLM_ORC_URL=http://127.0.0.1:8765`, exported in `~/.zshrc`
for shells and added to the supervisor plist's `EnvironmentVariables`
(along with `/usr/local/bin` on PATH) for the daemon. `remote-pi install`
rewrites that plist, so re-add both keys if it is ever re-run.

Two remote-pi copies conflict: the supervisor passes its global copy with
`-e`, and if `settings.json` also lists `npm:remote-pi` the tools register
twice and the daemon crash-loops. So on the mini `settings.json` points at
the same global path (`pi install $(npm root -g)/remote-pi/dist/index.js`);
Pi dedupes an identical path. That path contains the Node version, so
after an `nvm install` to a newer Node: `npm i -g remote-pi`,
`pi install <new path>`, `remote-pi install`, re-add the plist keys.

Pairing the mini is interactive, and the order matters:
`remote-pi daemon stop` FIRST, then `ssh -t ng-mini`, `cd ~/agents/mini`,
`pi`, `/remote-pi`, `/remote-pi pair`, scan, quit `pi`, then
`remote-pi daemon start`. A daemon left running during pairing polls the
phone's member list every 60 s and, if its own key is not in it (it was on
another key, or the list was published a moment before it), treats that as
a revocation and empties `~/.pi/remote/peers.json` (upstream #95/#69).
That is how the first pairing on 2026-09-18 was lost.

The agent name in `~/agents/mini/.pi/remote-pi/config.json` must stay
`mini`, equal to the folder name: the relay room is derived from the cwd
alone when the name is the folder's default, and from cwd+name otherwise.
The daemon's registry name is `mini`, so an interactive session with any
other name pairs the phone into a room the daemon never joins.

Identity is file-backed on the mini: `REMOTE_PI_ALLOW_FILE_IDENTITY=1` in
`~/.zshrc` and in the supervisor plist. An ssh session cannot reach the
login Keychain ("keychain is locked or access was denied"), while the
LaunchAgent in the GUI session can, so without the flag the two contexts
would hold different Pi-keys and a pairing made over ssh would not cover
the daemon. `~/.pi/remote/identity.json` (0600) wins over the Keychain for
every process once it exists, so both converge on it; the daemon needs one
restart after the file is minted. Back that file up with the rest of
`~/.pi/remote/`; losing it means re-pairing.

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
