# github-runner

Self-hosted GitHub Actions runner image based on Ubuntu 24.04.

Pushed to GHCR automatically on every push to `main` by
[`build-image.yml`](.github/workflows/build-image.yml). The build resolves the
latest [actions/runner](https://github.com/actions/runner/releases) release
automatically; pass `--build-arg RUNNER_VERSION=x.y.z` to pin one.

## Included tooling

- build-essential, git, curl, wget, jq, zip/unzip, rsync, openssh-client
- .NET SDK 10 (override with `--build-arg DOTNET_CHANNEL=...`)
- Node.js LTS + npm
- Python 3 + pip + venv
- Docker CLI + Buildx + Compose (uses the host daemon via socket mount)
- GitHub CLI (`gh`)

## Usage

With docker compose (recommended):

```sh
cp .env.example .env   # then fill in GITHUB_URL and GITHUB_PAT
docker compose up -d   # starts runner-1..3, workspaces in ./workspaces/<name>
```

Each service bind-mounts its workspace to a separate local folder
(`./workspaces/runner-1` etc.). Add or remove runners by copying/deleting a
service block in `docker-compose.yml`.

Optionally, give the runner a dedicated unprivileged host identity first:

```sh
sudo scripts/create-runner-user.sh
```

This creates a no-login, no-home `github-runner` user and group on the host,
using `PUID`/`PGID` from `.env` if set (otherwise it assigns system ids and
writes them back to `.env`). Workspace files then belong to that account
instead of an arbitrary uid.

Or plain `docker run`:

```sh
docker run -d --restart unless-stopped \
  -e GITHUB_URL=https://github.com/<org-or-owner/repo> \
  -e GITHUB_PAT=<pat with repo/admin:org scope> \
  -e RUNNER_LABELS=docker,linux \
  ghcr.io/themoddingbordello/github-runner:latest
```

The runner deregisters itself on container stop.

### Environment variables

| Variable           | Required | Description                                                                     |
|--------------------|----------|---------------------------------------------------------------------------------|
| `GITHUB_URL`       | yes      | Org (`https://github.com/my-org`) or repo (`https://github.com/owner/repo`) URL |
| `GITHUB_PAT`       | yes*     | PAT used to fetch registration/removal tokens automatically                     |
| `RUNNER_TOKEN`     | yes*     | Pre-generated registration token (alternative to `GITHUB_PAT`)                  |
| `RUNNER_NAME`      | no       | Runner name (default: container hostname)                                       |
| `RUNNER_LABELS`    | no       | Comma-separated labels (default: `docker`)                                      |
| `RUNNER_GROUP`     | no       | Runner group (org runners)                                                      |
| `RUNNER_WORKDIR`   | no       | Work directory (default: `/mnt/agent/workspace`)                                |
| `RUNNER_EPHEMERAL` | no       | `true` to take one job and exit                                                 |
| `RUNNER_CLEAN_FS`  | no       | `true` to reset the writable FS on start (default: `RUNNER_EPHEMERAL`'s value)  |
| `PUID`             | no       | uid the runner process runs as (default: `1000`)                                |
| `PGID`             | no       | gid the runner process runs as (default: `1000`)                                |

\* one of `GITHUB_PAT` / `RUNNER_TOKEN` is required. With `RUNNER_TOKEN` only,
deregistration on stop uses the same token, which may have expired by then —
prefer `GITHUB_PAT` for long-lived runners.

### Ephemeral runners

Set `RUNNER_EPHEMERAL=true` in `.env`. The runner then registers with
`--ephemeral`: it accepts exactly **one** job, GitHub deregisters it
automatically when the job finishes, and the container exits. Compose's
`restart: unless-stopped` immediately starts it again and the entrypoint
registers a brand-new runner.

Ephemeral mode also turns on `RUNNER_CLEAN_FS` (settable independently): on
every start the entrypoint resets `/mnt/agent` from a pristine build-time
snapshot and empties `/tmp`, `/var/tmp` and `/dev/shm`. Those are the only
locations an unprivileged job can write, so a restarted container is
equivalent to a recreated one — jobs cannot leave anything behind.

### User and privileges

The container starts as root, remaps the in-container `runner` user to
`PUID`/`PGID`, then drops privileges via `gosu` — the runner process and all
jobs run unprivileged (there is no sudo). If a docker socket is mounted, the
entrypoint matches the `docker` group to the socket's gid automatically, so no
`group_add` or `DOCKER_GID` configuration is needed.

Everything the agent may write lives under `/mnt/agent`:

```
/mnt/agent/runner      runner installation, credentials, diagnostic logs
/mnt/agent/home        the runner user's $HOME (tool caches: ~/.npm, ~/.nuget, ...)
/mnt/agent/workspace   job working directory (RUNNER_WORKDIR)
```

Each compose service bind-mounts its workspace to `./workspaces/<service>` on
the host, so runners never share a working directory and job output is
inspectable locally.

## Hardening

`docker-compose.yml` applies defense in depth for running semi-trusted jobs:

- **Capabilities** — `cap_drop: ALL`, adding back only the five the
  entrypoint's root phase needs (`CHOWN`, `SETUID`, `SETGID`, `FOWNER`,
  `DAC_OVERRIDE`). After the privilege drop, jobs run with none.
- **`no-new-privileges`** — setuid/setgid binaries can't re-escalate.
- **AppArmor** ([`apparmor/github-runner`](apparmor/github-runner)) — confines
  writes to `/mnt/agent`, `/tmp`, `/var/tmp` and `/dev/shm`; denies reading
  `/home` and `/root` entirely; denies mount/pivot_root; and re-enforces the
  capability drop at the MAC layer. Install it on the host first:

  ```sh
  sudo apparmor/install.sh
  ```

  This copies the profile to `/etc/apparmor.d/` (persists across reboots) and
  loads it. Docker refuses to start the container until the profile is loaded.
  If a job fails on a denial, reinstall with `sudo apparmor/install.sh
  --complain` (logs instead of blocks), rerun the job, and watch
  `journalctl -kf | grep -i apparmor` to see what to whitelist.
- **`pids_limit`** — fork-bomb protection; memory/CPU limits are stubbed in
  the compose file.
- **Docker socket is opt-in** (commented out): socket access is equivalent to
  root on the host and defeats all of the above. Only enable it for runners
  that execute exclusively trusted workflows.

Operational practices worth following for exposed runners:

- **Never attach self-hosted runners to public repositories** — fork PRs can
  execute arbitrary code on them.
- Prefer `RUNNER_EPHEMERAL=true`: one job per container, and `RUNNER_CLEAN_FS`
  resets every job-writable location between jobs — nothing for an attacker
  to persist in.
- Pull and recreate regularly to pick up image and runner updates
  (`docker compose up -d --force-recreate --pull always`).
- Scope the PAT minimally (`repo`, or a fine-grained token with runner
  registration only) and consider repo-level over org-level registration.
- Consider egress filtering/monitoring (e.g. StepSecurity Harden-Runner or a
  network-level allowlist) — exfiltration via outbound HTTPS is the main
  remaining channel.
