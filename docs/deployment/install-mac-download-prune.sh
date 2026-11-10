#!/bin/sh
# CODE ONLY. Sam must review and run explicitly on the downloads server, after
# setup-mac-downloads.sh. Safe to re-run: it replaces the three files and
# restarts nothing but the timer. It never deletes zips itself.
# Usage: sudo sh install-mac-download-prune.sh
set -eu
[ "$(id -u)" = 0 ] || { echo 'Run as root after review' >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
id term-llm-updates >/dev/null 2>&1 || { echo 'Run setup-mac-downloads.sh first' >&2; exit 1; }
[ -d /var/www/term-llm-downloads/mac ] || { echo 'Missing /var/www/term-llm-downloads/mac' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'Install python3 first' >&2; exit 1; }
install -o root -g root -m 0755 "$here/term-llm-mac-prune" /usr/local/sbin/term-llm-mac-prune
install -o root -g root -m 0644 "$here/term-llm-mac-prune.service" "$here/term-llm-mac-prune.timer" /etc/systemd/system/
systemctl daemon-reload
echo '== Dry run as the upload account (nothing is deleted):'
runuser -u term-llm-updates -- /usr/local/sbin/term-llm-mac-prune --dry-run
systemctl enable --now term-llm-mac-prune.timer
systemctl list-timers term-llm-mac-prune.timer --no-pager
