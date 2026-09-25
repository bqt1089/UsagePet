#!/usr/bin/env bash
# P0: đọc OAuth token của Claude Code (Keychain) và gọi GET /api/oauth/usage 1 lần.
# CẢNH BÁO: request READ-ONLY lên hệ thống PROD của Anthropic, dùng token của bạn.
# Token không được in ra, không ghi file.
set -euo pipefail

echo "⚠️  Script sẽ gọi GET https://api.anthropic.com/api/oauth/usage (PROD, read-only)."
read -r -p "Gõ 'yes' để tiếp tục: " ok; [[ "$ok" == "yes" ]] || { echo "Huỷ."; exit 1; }

raw="$(/usr/bin/security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null || true)"
if [[ -z "$raw" && -f "$HOME/.claude/.credentials.json" ]]; then raw="$(cat "$HOME/.claude/.credentials.json")"; fi
[[ -n "$raw" ]] || { echo "Không tìm thấy credentials. Chạy 'claude' rồi /login."; exit 1; }

token="$(printf '%s' "$raw" | /usr/bin/python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("claudeAiOauth",{}).get("accessToken",""))')"
[[ -n "$token" ]] || { echo "Không parse được accessToken (schema khác?)."; exit 1; }

curl -sS -w '\nHTTP %{http_code}\n' \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Accept: application/json" \
  https://api.anthropic.com/api/oauth/usage | /usr/bin/python3 -c '
import sys,json
t=sys.stdin.read(); body,_,code=t.rpartition("\nHTTP ")
print("HTTP",code.strip())
try: print(json.dumps(json.loads(body),indent=2))
except Exception: print(body)'
echo
echo "→ Mở Claude Code, gõ /usage và so với số ở trên (five_hour, seven_day, seven_day_oauth_apps)."
