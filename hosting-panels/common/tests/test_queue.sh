#!/bin/bash
# Copyright © 2025-2026 SecondDNS
# Licensed under GNU General Public License v3.0 or SecondDNS Commercial License
# See LICENSE (GPLv3) or LICENSE.COMMERCIAL (commercial) for details
# Self-contained test suite for seconddns-queue.
# Requires: bash, sqlite3, curl, python3. No network access needed.
#
# Usage: ./test_queue.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
QUEUE="$HERE/../seconddns-queue"
TMP="$(mktemp -d)"
PORT=8899

export SECONDDNS_CONF="$TMP/seconddns.conf"
export SECONDDNS_QUEUE_DB="$TMP/queue.db"
export SECONDDNS_QUEUE_LOCK="$TMP/queue.lock"
export SECONDDNS_LOG="$TMP/seconddns.log"

cat > "$SECONDDNS_CONF" <<EOF
[seconddns]
api_url = http://127.0.0.1:$PORT
api_key = test-key
master_ip = 192.0.2.10
EOF

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || fail "$3 (expected '$2', got '$1')"; }

pending() { sqlite3 "$SECONDDNS_QUEUE_DB" "SELECT COUNT(*) FROM ops WHERE status='pending';"; }
failed()  { sqlite3 "$SECONDDNS_QUEUE_DB" "SELECT COUNT(*) FROM ops WHERE status='failed';"; }

# Mock API: behavior driven by $TMP/mode file
#   ok      — create 201, by-name 200 {id}, delete 204
#   dup     — create 409, by-name/delete 404
#   down    — all requests 503
#   badreq  — create 400
#   record  — like ok, and appends "METHOD PATH" lines to $TMP/requests.log
python3 - "$PORT" "$TMP" > /dev/null 2>&1 <<'PYEOF' &
import http.server, sys, os, json
port, tmp = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def mode(self):
        try: return open(tmp+'/mode').read().strip()
        except Exception: return 'ok'
    def log_message(self, *a): pass
    def reply(self, code, body=b'{}'):
        self.send_response(code)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(body)
    def record(self):
        with open(tmp+'/requests.log','a') as f:
            f.write(f"{self.command} {self.path.split('?')[0]}\n")
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        m=self.mode()
        if m in ('ok','record'):
            if m=='record': self.record()
            self.reply(201, b'{"id":"z1"}')
        elif m=='dup': self.reply(409, b'{"error":"exists"}')
        elif m=='badreq': self.reply(400, b'{"error":"invalid"}')
        else: self.reply(503)
    def do_GET(self):
        m=self.mode()
        if m in ('ok','record'):
            if m=='record': self.record()
            self.reply(200, b'{"id":"z1"}')
        elif m=='dup': self.reply(404)
        else: self.reply(503)
    def do_DELETE(self):
        m=self.mode()
        if m in ('ok','record'):
            if m=='record': self.record()
            self.reply(204, b'')
        elif m=='dup': self.reply(404)
        else: self.reply(503)
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PYEOF
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null; rm -rf "$TMP"' EXIT
sleep 1

echo "== 1. enqueue writes rows"
"$QUEUE" enqueue create example.com 192.0.2.10
"$QUEUE" enqueue delete old.example.com
assert_eq "$(pending)" 2 "two ops pending"

echo "== 2. API down: drain stops, order kept"
echo down > "$TMP/mode"
"$QUEUE" flush
assert_eq "$(pending)" 2 "nothing lost while API is down"
attempts=$(sqlite3 "$SECONDDNS_QUEUE_DB" "SELECT attempts FROM ops ORDER BY id LIMIT 1;")
assert_eq "$attempts" 1 "first op attempt counted"

echo "== 3. API up: queue drains in FIFO order"
echo record > "$TMP/mode"
: > "$TMP/requests.log"
"$QUEUE" flush
assert_eq "$(pending)" 0 "queue drained"
first_req=$(head -1 "$TMP/requests.log")
assert_eq "$first_req" "POST /api/zones" "create delivered first (FIFO)"

echo "== 4. duplicate delivery: 409/404 treated as success"
echo dup > "$TMP/mode"
"$QUEUE" enqueue create example.com 192.0.2.10
"$QUEUE" enqueue delete example.com
"$QUEUE" flush
assert_eq "$(pending)" 0 "409 create and 404 delete drained as success"
assert_eq "$(failed)" 0 "no failed rows"

echo "== 5. hard error: marked failed, queue continues"
echo badreq > "$TMP/mode"
"$QUEUE" enqueue create "bad domain" 192.0.2.10
echo ok > "$TMP/mode.next" # placeholder to show intent
"$QUEUE" flush
assert_eq "$(failed)" 1 "400 marked failed"
assert_eq "$(pending)" 0 "failed op does not block the queue"

echo "== 6. status output and exit codes"
out=$("$QUEUE" status --json); rc=$?
assert_eq "$rc" 2 "exit 2 when failed ops present"
echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['failed']==1" \
    && ok "status --json parses with failed=1" || fail "status --json content"
sqlite3 "$SECONDDNS_QUEUE_DB" "DELETE FROM ops;"
"$QUEUE" status > /dev/null; rc=$?
assert_eq "$rc" 0 "exit 0 when queue empty"

echo "== 7. concurrency: 20 parallel enqueues, none lost"
enq_pids=()
for i in $(seq 1 20); do
    "$QUEUE" enqueue create "conc$i.example.com" 192.0.2.10 &
    enq_pids+=($!)
done
wait "${enq_pids[@]}"
assert_eq "$(pending)" 20 "all 20 concurrent enqueues persisted"
echo ok > "$TMP/mode"
"$QUEUE" flush
assert_eq "$(pending)" 0 "all 20 drained"

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
