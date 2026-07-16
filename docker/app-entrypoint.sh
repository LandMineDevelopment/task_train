#!/usr/bin/env bash
set -euo pipefail

mkdir -p /home/app/.local/share/opencode /home/app/.config/opencode
chown -R app:app /home/app/.local /home/app/.config
exec runuser -u app -- "$@"
