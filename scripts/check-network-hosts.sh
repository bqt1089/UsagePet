#!/usr/bin/env bash
# Fails if app code references any network host other than the allowed ones.
# Runs in CI on every push/PR so a change that sends data elsewhere is caught.
set -euo pipefail
ALLOWED='^(api\.anthropic\.com|docs\.claude\.com|github\.com|127\.0\.0\.1)$'
hosts=$(grep -rhoE 'https?://[A-Za-z0-9.-]+' Sources --include='*.swift' \
  | sed -E 's#https?://##' | sort -u)
bad=0
for h in $hosts; do
  if ! [[ "$h" =~ $ALLOWED ]]; then echo "Unexpected network host in code: $h"; bad=1; fi
done
[ "$bad" -eq 0 ] && echo "Network hosts OK: $(echo $hosts | tr '\n' ' ')"
exit $bad
