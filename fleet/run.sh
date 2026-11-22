#!/usr/bin/env bash
# fleet/run.sh - one command reaches every host (through the bastion) and
# reports clearly per host, continuing even if one host fails.
#
# Usage:
#   fleet/run.sh              -> default task (system snapshot on each host)
#   fleet/run.sh '<command>'  -> run <command> on every host
#
# Hosts are resolved via ~/.ssh/config, so client1/client2 ProxyJump through the bastion.
set -uo pipefail        # no -e on purpose: one failure must not stop the loop

FLEET=(bastion client1 client2 loghost)

if [ "$#" -ge 1 ]; then CMD="$1"; else
  CMD='echo "host=$(hostname)"; uptime | sed "s/^ *//"; free -h | grep ^Mem'
fi

declare -A RESULT
overall=0
for h in "${FLEET[@]}"; do
  echo "=================================================="
  echo ">>> $h"
  echo "=================================================="
  if ssh -o BatchMode=yes -o ConnectTimeout=15 "$h" "$CMD"; then
    RESULT[$h]="OK"
  else
    RESULT[$h]="FAIL"
    overall=1
  fi
  echo
done

echo "==================== SUMMARY ====================="
for h in "${FLEET[@]}"; do printf "  %-10s %s\n" "$h" "${RESULT[$h]}"; done
echo "=================================================="
exit $overall
