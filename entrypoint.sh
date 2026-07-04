#!/bin/bash
set -euo pipefail

# Required:
#   GITHUB_URL    org or repo URL, e.g. https://github.com/my-org or https://github.com/owner/repo
#   and one of:
#     RUNNER_TOKEN  a pre-generated registration token
#     GITHUB_PAT    a PAT used to fetch registration/removal tokens automatically
# Optional:
#   PUID, PGID (default: 1000) uid/gid to run the runner as
#   RUNNER_NAME (default: hostname), RUNNER_LABELS (comma-separated),
#   RUNNER_GROUP, RUNNER_WORKDIR (default: /mnt/agent/workspace),
#   RUNNER_EPHEMERAL=true
#   RUNNER_CLEAN_FS=true  reset /mnt/agent + scratch dirs to a pristine
#                         snapshot on start (default: value of RUNNER_EPHEMERAL)

# When started as root: remap the runner user to PUID/PGID, grant access to a
# mounted docker socket, then re-exec this script as the runner user.
if [[ "$(id -u)" == "0" ]]; then
    PUID="${PUID:-1000}"
    PGID="${PGID:-1000}"

    if [[ "$(id -g runner)" != "${PGID}" ]]; then
        groupmod -o -g "${PGID}" runner
    fi
    if [[ "$(id -u runner)" != "${PUID}" ]]; then
        usermod -o -u "${PUID}" runner
    fi

    # Reset every job-writable location to its pristine state. Everything
    # else in the container is write-protected (unprivileged user + AppArmor),
    # so this makes a restarted container equivalent to a recreated one.
    if [[ "${RUNNER_CLEAN_FS:-${RUNNER_EPHEMERAL:-false}}" == "true" ]]; then
        echo "Resetting agent filesystem to pristine state..."
        find /mnt/agent /tmp /var/tmp /dev/shm -mindepth 1 -delete 2> /dev/null || true
        tar -C / -xzf /opt/agent-skel.tar.gz
    fi

    if [[ "$(stat -c '%u:%g' /mnt/agent)" != "${PUID}:${PGID}" ]]; then
        chown -R runner:runner /mnt/agent
    fi

    # A bind-mounted workspace starts out root-owned on first run
    workdir="${RUNNER_WORKDIR:-/mnt/agent/workspace}"
    mkdir -p "${workdir}"
    if [[ "$(stat -c '%u:%g' "${workdir}")" != "${PUID}:${PGID}" ]]; then
        chown -R runner:runner "${workdir}"
    fi

    if [[ -S /var/run/docker.sock ]]; then
        sock_gid="$(stat -c '%g' /var/run/docker.sock)"
        if ! getent group "${sock_gid}" > /dev/null; then
            groupmod -o -g "${sock_gid}" docker
        fi
        usermod -aG "$(getent group "${sock_gid}" | cut -d: -f1)" runner
    fi

    exec gosu runner "$0" "$@"
fi

GITHUB_URL="${GITHUB_URL:?GITHUB_URL is required (org or repo URL)}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-docker}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/mnt/agent/workspace}"

# Clear stale registration state (e.g. after an ephemeral run + container restart)
rm -f .runner .credentials .credentials_rsaparams

# Ephemeral runners start each job with a clean workspace
if [[ "${RUNNER_EPHEMERAL:-}" == "true" && -d "${RUNNER_WORKDIR}" ]]; then
    find "${RUNNER_WORKDIR}" -mindepth 1 -delete 2> /dev/null || true
fi

scope_path="${GITHUB_URL#https://github.com/}"
if [[ "${scope_path}" == */* ]]; then
    token_api="https://api.github.com/repos/${scope_path}/actions/runners"
else
    token_api="https://api.github.com/orgs/${scope_path}/actions/runners"
fi

fetch_token() { # registration-token | remove-token
    curl -fsSL -X POST \
        -H "Authorization: Bearer ${GITHUB_PAT}" \
        -H "Accept: application/vnd.github+json" \
        "${token_api}/$1" | jq -r '.token'
}

if [[ -z "${RUNNER_TOKEN:-}" ]]; then
    : "${GITHUB_PAT:?Provide RUNNER_TOKEN or GITHUB_PAT}"
    RUNNER_TOKEN="$(fetch_token registration-token)"
fi

config_args=(
    --url "${GITHUB_URL}"
    --token "${RUNNER_TOKEN}"
    --name "${RUNNER_NAME}"
    --labels "${RUNNER_LABELS}"
    --work "${RUNNER_WORKDIR}"
    --unattended
    --replace
)
[[ -n "${RUNNER_GROUP:-}" ]] && config_args+=(--runnergroup "${RUNNER_GROUP}")
[[ "${RUNNER_EPHEMERAL:-}" == "true" ]] && config_args+=(--ephemeral)

./config.sh "${config_args[@]}"

cleaned_up=false
cleanup() {
    [[ "${cleaned_up}" == "true" ]] && return
    cleaned_up=true
    echo "Deregistering runner..."
    local token="${RUNNER_TOKEN}"
    if [[ -n "${GITHUB_PAT:-}" ]]; then
        token="$(fetch_token remove-token)" || token="${RUNNER_TOKEN}"
    fi
    ./config.sh remove --token "${token}" || true
}
trap cleanup EXIT

./run.sh &
RUNNER_PID=$!
trap 'kill -TERM "${RUNNER_PID}" 2>/dev/null || true' TERM INT
wait "${RUNNER_PID}" || true
wait "${RUNNER_PID}" 2>/dev/null || true
