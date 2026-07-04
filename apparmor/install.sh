#!/bin/bash
# Installs the github-runner AppArmor profile on the host.
#
# Usage:
#   sudo apparmor/install.sh              # install + enforce
#   sudo apparmor/install.sh --complain   # install in complain mode (log denials, don't block)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/github-runner"
DST="/etc/apparmor.d/github-runner"

PARSER_ARGS=()
if [[ "${1:-}" == "--complain" ]]; then
    PARSER_ARGS+=(--Complain)
    echo "Installing in COMPLAIN mode — denials are logged, not blocked."
    echo "Watch them with: journalctl -kf | grep -i apparmor"
fi

if [[ "$(id -u)" != "0" ]]; then
    echo "Run as root: sudo $0 $*" >&2
    exit 1
fi

if [[ ! -d /sys/kernel/security/apparmor ]]; then
    echo "AppArmor is not enabled on this host kernel." >&2
    exit 1
fi

if ! command -v apparmor_parser > /dev/null; then
    echo "apparmor_parser not found — install the 'apparmor' package first." >&2
    exit 1
fi

install -m 0644 "${SRC}" "${DST}"
apparmor_parser -r "${PARSER_ARGS[@]}" "${DST}"

if aa-status 2> /dev/null | grep -q 'github-runner'; then
    echo "Profile 'github-runner' installed to ${DST} and loaded."
else
    echo "Profile installed to ${DST} and loaded (could not verify via aa-status)."
fi
echo "Start the runner with: docker compose up -d"
