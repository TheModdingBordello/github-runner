#!/bin/bash
# Creates a dedicated `github-runner` host account (no login shell, no home
# directory) for the containerized runner, so files written to bind-mounted
# workspaces belong to a real, unprivileged host user.
#
# Usage: sudo scripts/create-runner-user.sh
#
# PUID/PGID are taken from .env when set; otherwise a system account is
# created and the assigned ids are written back to .env.
set -euo pipefail

NAME=github-runner
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_DIR}/.env"

die() {
    echo "$*" >&2
    exit 1
}

[[ "$(id -u)" == "0" ]] || die "Run as root: sudo $0"
[[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} not found — cp .env.example .env first"

env_get() {
    grep -E "^$1=" "${ENV_FILE}" | tail -n 1 | cut -d= -f2- || true
}

PUID="$(env_get PUID)"
PGID="$(env_get PGID)"

# Group
if getent group "${NAME}" > /dev/null; then
    existing_gid="$(getent group "${NAME}" | cut -d: -f3)"
    if [[ -n "${PGID}" && "${PGID}" != "${existing_gid}" ]]; then
        die "Group '${NAME}' already exists with gid ${existing_gid}, but .env has PGID=${PGID}"
    fi
    PGID="${existing_gid}"
    echo "Group '${NAME}' already exists (gid ${PGID})."
else
    groupadd -r ${PGID:+-g "${PGID}"} "${NAME}"
    PGID="$(getent group "${NAME}" | cut -d: -f3)"
    echo "Created group '${NAME}' (gid ${PGID})."
fi

# User
if id -u "${NAME}" &> /dev/null; then
    existing_uid="$(id -u "${NAME}")"
    if [[ -n "${PUID}" && "${PUID}" != "${existing_uid}" ]]; then
        die "User '${NAME}' already exists with uid ${existing_uid}, but .env has PUID=${PUID}"
    fi
    PUID="${existing_uid}"
    echo "User '${NAME}' already exists (uid ${PUID})."
else
    useradd -r -M \
        ${PUID:+-u "${PUID}"} \
        -g "${NAME}" \
        -d /nonexistent \
        -s /usr/sbin/nologin \
        "${NAME}"
    PUID="$(id -u "${NAME}")"
    echo "Created user '${NAME}' (uid ${PUID}, no login, no home)."
fi

# Record the ids in .env so the container maps its runner user onto this account
env_set() {
    if grep -qE "^$1=" "${ENV_FILE}"; then
        return
    elif grep -qE "^#\s*$1=" "${ENV_FILE}"; then
        sed -i -E "s|^#\s*$1=.*|$1=$2|" "${ENV_FILE}"
    else
        printf '%s=%s\n' "$1" "$2" >> "${ENV_FILE}"
    fi
    echo "Set $1=$2 in .env"
}
env_set PUID "${PUID}"
env_set PGID "${PGID}"

echo "Done. Containers started via docker compose will run jobs as ${NAME} (${PUID}:${PGID})."
