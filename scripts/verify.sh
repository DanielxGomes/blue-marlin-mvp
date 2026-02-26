#!/usr/bin/env bash
set -euo pipefail

npx --yes htmlhint "*.html"

grep -R "BEGIN;" db/migrations/*.sql >/dev/null
grep -R "COMMIT;" db/migrations/*.sql >/dev/null

python3 -m http.server 18080 >/tmp/web.log 2>&1 &
PID=$!
trap 'kill $PID >/dev/null 2>&1 || true' EXIT
sleep 2
curl -fsS http://127.0.0.1:18080/index.html >/dev/null
curl -fsS http://127.0.0.1:18080/admin.html >/dev/null

echo "OK: verify"
