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

```sh
docker run -d --restart unless-stopped \
  -e GITHUB_URL=https://github.com/<org-or-owner/repo> \
  -e GITHUB_PAT=<pat with repo/admin:org scope> \
  -e RUNNER_LABELS=docker,linux \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/0x25cbfc4f/github-runner:latest
```

The runner deregisters itself on container stop.

### Environment variables

| Variable | Required | Description |
|---|---|---|
| `GITHUB_URL` | yes | Org (`https://github.com/my-org`) or repo (`https://github.com/owner/repo`) URL |
| `GITHUB_PAT` | yes* | PAT used to fetch registration/removal tokens automatically |
| `RUNNER_TOKEN` | yes* | Pre-generated registration token (alternative to `GITHUB_PAT`) |
| `RUNNER_NAME` | no | Runner name (default: container hostname) |
| `RUNNER_LABELS` | no | Comma-separated labels (default: `docker`) |
| `RUNNER_GROUP` | no | Runner group (org runners) |
| `RUNNER_WORKDIR` | no | Work directory (default: `_work`) |
| `RUNNER_EPHEMERAL` | no | `true` to take one job and exit |

\* one of `GITHUB_PAT` / `RUNNER_TOKEN` is required. With `RUNNER_TOKEN` only,
deregistration on stop uses the same token, which may have expired by then —
prefer `GITHUB_PAT` for long-lived runners.

If jobs need Docker, mount the host socket as shown above. If the socket's
group id on the host differs from the image's `docker` group, add
`--group-add $(stat -c '%g' /var/run/docker.sock)` to `docker run`.
