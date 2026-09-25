#!/usr/bin/env bash
# P0 (Antigravity app): find the running Antigravity language server, then ask it
# for the quota summary. Talks ONLY to 127.0.0.1 (the app's own local server),
# read-only. The CSRF token is never printed.
set -uo pipefail

line=$(ps -axww -o pid=,command= | grep -i -- '--csrf_token' | grep -i 'antigravity' | grep -v grep | head -1)
if [[ -z "$line" ]]; then
  echo "Không thấy tiến trình Antigravity có --csrf_token. Hãy mở app Antigravity rồi chạy lại."
  exit 1
fi
pid=$(awk '{print $1}' <<<"$line")
token=$(grep -oE -- '--csrf_token[= ][^ ]+' <<<"$line" | head -1 | sed -E 's/--csrf_token[= ]//')
echo "PID: $pid"
echo "Binary: $(awk '{print $2}' <<<"$line" | sed -E 's#.*/##')"
echo "CSRF token: tìm thấy (${#token} ký tự, không in ra)"
echo "Flags (đã ẩn mọi giá trị):"
tr ' ' '\n' <<<"$line" | grep -E '^--' | sed -E 's/^(--[A-Za-z_]*(token|secret|key)[A-Za-z_]*)([= ].*)?$/\1=<hidden>/I; s/^(--[A-Za-z_]+)=.*/\1=…/' | sort -u | head -30

ports=$(lsof -nP -a -iTCP -sTCP:LISTEN -p "$pid" 2>/dev/null | awk 'NR>1{print $9}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -u)
echo "Cổng đang nghe: ${ports:-<không có>}"

for port in $ports; do
  for method in RetrieveUserQuotaSummary GetUserStatus; do
    for scheme in https http; do
      out=$(curl -sk --max-time 4 -w '\n%{http_code}' -X POST \
        "$scheme://127.0.0.1:$port/exa.language_server_pb.LanguageServerService/$method" \
        -H "Content-Type: application/json" -H "Connect-Protocol-Version: 1" \
        -H "X-Codeium-Csrf-Token: $token" -d '{}' 2>/dev/null)
      code=$(tail -n1 <<<"$out"); body=$(sed '$d' <<<"$out")
      if [[ "$code" == "200" ]]; then
        echo; echo "=== $scheme :$port $method → HTTP 200 ==="
        /usr/bin/python3 -c 'import sys,json
try: print(json.dumps(json.loads(sys.stdin.read()),indent=2)[:12000])
except Exception as e: print("(không phải JSON)")' <<<"$body"
        [[ "$method" == "RetrieveUserQuotaSummary" ]] && exit 0
      elif [[ -n "$code" && "$code" != "000" ]]; then
        echo "$scheme :$port $method → HTTP $code"
      fi
    done
  done
done
echo; echo "Chưa lấy được quota. Paste toàn bộ output này cho Claude."
