# Running a vault inbox peer

The vault inbox peer is a Node 22 process (`node inbox.mjs`) that joins an
Obsidian vault's sync server as one more device and runs llm-orc
ensembles for request notes. It runs under launchd as a user agent, so it
starts at login and restarts when it exits.

Nothing about a particular machine is tracked: `vault-peer-deploy.sh`
renders the agent from `launchd/vault-peer.plist.template` with the values
in that machine's `config.sh` (see the vault peer section of
`config.example.sh`; every value has a default).

## Install

The peer's code is installed by hand, not by this repo. Copy it to the
machine and install its dependencies:

    rsync -a --exclude node_modules <peer-code>/ remote-host:~/og-cloud-headless/
    ssh remote-host 'cd ~/og-cloud-headless && npm install'

Node 22 comes from nvm (`~/.nvm/nvm.sh`). The wrapper sources nvm and runs
`nvm use 22` at every start, so a new 22.x patch is picked up on restart.
Set `VAULT_PEER_NODE` in `config.sh` to an absolute path to skip nvm.

## The env file

Settings live in `.env` next to the code, mode 600. Write it by hand; the
deploy script never creates it and never reads the token.

    OG_HOST=...         # the sync server
    OG_VAULT_ID=...
    OG_TOKEN=...        # shared by every device on the vault
    OG_DEVICE=...       # a name for this peer
    LLM_ORC_URL=http://127.0.0.1:8765
    GARDEN_HOUR=3       # optional

Then `chmod 600 ~/og-cloud-headless/.env`. The token is the vault's token,
so this peer is one more device sharing it. Rotating it means updating the
`.env` here too.

## Deploy

    ./vault-peer-deploy.sh                # check, render, load, confirm it stays up
    ./vault-peer-deploy.sh --dry-run      # print the wrapper and unit and what would change
    ./vault-peer-deploy.sh --render-only  # print them and exit, no checks

The script refuses to run if `.env` is missing or not mode 600, or if
`node_modules` is missing (run `npm install`). It writes `run.sh` in the
peer's directory (the wrapper that loads nvm and `.env`, then execs
`node inbox.mjs`) and the unit in `~/Library/LaunchAgents/`. A changed
unit is reloaded with bootout and bootstrap, an unchanged one is
kickstarted. Run it again after copying new code.

## Doctor

`homelab doctor` check 12 runs only when `.env` exists in the peer's
directory. It passes when the agent is running and either the log was
written in the last 15 minutes or the process exists. With `--fix` it
kickstarts the agent.

## Logs and stopping

    tail -f ~/Library/Logs/vault-peer.log
    launchctl print gui/$(id -u)/com.vault-peer.inbox | grep -E 'state|pid'

To stop it until the next login, `launchctl bootout
gui/$(id -u)/com.vault-peer.inbox`. To remove it, bootout and delete
`~/Library/LaunchAgents/com.vault-peer.inbox.plist`. Doctor will fail the
check again while `.env` is present, so move that file too if the peer is
gone for good.
