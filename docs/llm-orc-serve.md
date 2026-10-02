# Running an llm-orc serve

The serve runs natively under launchd, bound to loopback, owning its
llama-server router. A reverse proxy app (nginx to the host's loopback
port) puts it behind the homelab's domain.

Nothing about a particular machine is tracked: `llm-orc-deploy.sh`
renders the unit from `launchd/com.llm-orc.serve.plist.template` with
the values in that machine's `config.sh` (see the llm-orc section of
`config.example.sh`; every value has a default).

## Deploy and update

    ./llm-orc-deploy.sh            # brew upgrade, render the unit, restart, wait for health
    ./llm-orc-deploy.sh --dry-run  # print the unit and what would change

From another machine, run the same script over ssh. It reloads the unit
with bootout + bootstrap when the unit changed (a kickstart keeps the old
arguments and working directory) and kickstarts otherwise. `homelab
doctor` check 11 also restarts a serve that answers with a version other
than the installed one.

## One-time setup

    brew tap mrilikecoding/llm-orchestra && brew install llm-orchestra
    ./llm-orc-deploy.sh --no-upgrade
    tail -f ~/Library/Logs/llm-orc-serve.log         # "llama-server router at ..."

The serve needs `llama-server` on the unit's PATH
(`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`). On Apple silicon
`brew install llama.cpp` provides it. Homebrew ships no Intel bottle, so
on an Intel Mac install the upstream binary and symlink it:

    tag=$(curl -sL https://github.com/ggml-org/llama.cpp/releases/latest/download/nightly-tag.txt)
    mkdir -p ~/opt/llama.cpp && cd ~/opt/llama.cpp
    curl -sL https://github.com/ggml-org/llama.cpp/releases/download/$tag/llama-$tag-bin-macos-x64.tar.gz | tar xz
    ln -sfn ~/opt/llama.cpp/llama-$tag ~/opt/llama.cpp/current
    ln -sf ~/opt/llama.cpp/current/llama-server /usr/local/bin/llama-server
    llama-server --help | grep -c models-preset               # must be > 0

Models download from Hugging Face on first use. To warm one ahead of
time: `curl -X POST http://127.0.0.1:8765/api/models/<model>/pull`.

## What the serve reads and writes

The brew release is the only thing the serve runs.

The unit's working directory is a plain directory with no `.llm-orc` in
it or above it (default `~/llm-orc-serve`); the deploy script refuses one
that has, because the serve would adopt it as a project and it would
shadow the serving project that ships in the package. User ensembles and
profiles live in `~/.config/llm-orc/` (CRUD with `scope: global`).
Runtime state (artifacts, `.serve-trace/`, `llama-server.ini`) lives in
`~/.local/state/llm-orc/`.

To list the ensembles of an `llm-orchestra-library` checkout, set
`LLM_ORC_LIBRARY_PATH` in `config.sh`.

## Checks

    curl http://127.0.0.1:8765/health
    curl http://127.0.0.1:8765/api/models
    curl http://127.0.0.1:8765/v1/models
