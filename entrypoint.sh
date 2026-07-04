#!/bin/bash
set -euo pipefail

# Required:
#   GITHUB_URL    org or repo URL, e.g. https://github.com/my-org or https://github.com/owner/repo
#   and one of:
#     RUNNER_TOKEN  a pre-generated registration token
#     GITHUB_PAT    a PAT used to fetch registration/removal tokens automatically
# Optional:
#   RUNNER_NAME (default: hostname), RUNNER_LABELS (comma-separated),
#   RUNNER_GROUP, RUNNER_WORKDIR (default: _work), RUNNER_EPHEMERAL=true

GITHUB_URL="${GITHUB_URL:?GITHUB_URL is required (org or repo URL)}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-docker}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"

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
