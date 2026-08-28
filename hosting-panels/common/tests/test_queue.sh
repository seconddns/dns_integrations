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
WORKER="$HERE/../seconddns-queued"
export SECONDDNS_QUEUED_BIN="$WORKER"
TMP="$(mktemp -d)"
PORT=8899

export SECONDDNS_CONF="$TMP/seconddns.conf"
export SECONDDNS_QUEUE_DB="$TMP/queue.db"
export SECONDDNS_QUEUE_LOCK="$TMP/queue.lock"
export SECONDDNS_LOG="$TMP/seconddns.log"
export SECONDDNS_QUEUE_SOCK="$TMP/w.sock"

cat > "$SECONDDNS_CONF" <<EOF
[seconddns]
api_url = http://127.0.0.1:$PORT
api_key = test-key
master_ip = 192.0.2.10

[queue]
poll_interval = 1
http_timeout = 5
backoff_min = 1
backoff_max = 2
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
    def special(self):
        m=self.mode()
        if m=='redirect':
            self.send_response(302); self.send_header('Location','/maintenance'); self.end_headers(); return True
        if m=='html':
            self.send_response(200); self.send_header('Content-Type','text/html'); self.end_headers()
            self.wfile.write(b'<html><body>We are down for maintenance</body></html>'); return True
        if m=='auth':
            self.reply(401, b'{"error":"invalid api key"}'); return True
        return False
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        if self.special(): return
        m=self.mode()
        if m in ('ok','record'):
            if m=='record': self.record()
            self.reply(201, b'{"id":"z1"}')
        elif m=='dup': self.reply(409, b'{"error":"exists"}')
        elif m=='badreq': self.reply(400, b'{"error":"invalid"}')
        else: self.reply(503)
    def do_GET(self):
        if self.special(): return
        m=self.mode()
        if m in ('ok','record'):
            if m=='record': self.record()
            self.reply(200, b'{"id":"z1"}')
        elif m=='dup': self.reply(404)
        elif m=='noid': self.reply(200, b'{}')
        else: self.reply(503)
    def do_DELETE(self):
        if self.special(): return
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
"$QUEUE" flush || true
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
# well-formed name; the 400 comes from the API, not from input validation
"$QUEUE" enqueue create rejected.example.com 192.0.2.10
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

echo "== 8. daemon mode: picks up new ops and survives an outage"
echo down > "$TMP/mode"
"$WORKER" & DPID=$!
sleep 1
"$QUEUE" enqueue create daemon1.example.com 192.0.2.10
"$QUEUE" enqueue create daemon2.example.com 192.0.2.10
sleep 2
assert_eq "$(pending)" 2 "ops wait while API is down"
echo ok > "$TMP/mode"
for i in $(seq 1 15); do [ "$(pending)" = 0 ] && break; sleep 1; done
assert_eq "$(pending)" 0 "daemon drained the queue after API recovery"
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null

echo "== 9. queue stores names verbatim, refuses unknown ops"
before=$(pending)
"$QUEUE" enqueue create "o'quote.example.com" 192.0.2.10
assert_eq "$(sqlite3 "$SECONDDNS_QUEUE_DB" "SELECT domain FROM ops ORDER BY id DESC LIMIT 1;")" \
    "o'quote.example.com" "single quote stored intact (SQL quoting)"
rc=0; "$QUEUE" enqueue purge valid.example.com 192.0.2.10 || rc=$?
assert_eq "$rc" 2 "rejected unknown op"
assert_eq "$(( $(pending) - before ))" 1 "one row added"
sqlite3 "$SECONDDNS_QUEUE_DB" "DELETE FROM ops;"

echo "== 10. delete lookup 200 without id: failed, queue continues"
echo noid > "$TMP/mode"
"$QUEUE" enqueue delete noid.example.com
"$QUEUE" flush
assert_eq "$(failed)" 1 "200-without-id marked failed"
assert_eq "$(pending)" 0 "queue not wedged behind it"
sqlite3 "$SECONDDNS_QUEUE_DB" "DELETE FROM ops;"

head_err() { sqlite3 "$SECONDDNS_QUEUE_DB" "SELECT IFNULL(last_error,'') FROM ops WHERE status='pending' ORDER BY id LIMIT 1;"; }
head_att() { sqlite3 "$SECONDDNS_QUEUE_DB" "SELECT attempts FROM ops WHERE status='pending' ORDER BY id LIMIT 1;"; }

echo "== 11. maintenance redirect (302): worker survives, op waits"
echo redirect > "$TMP/mode"
"$QUEUE" enqueue create maint.example.com 192.0.2.10
"$QUEUE" flush; rc=$?
assert_eq "$rc" 1 "flush reports API down"
assert_eq "$(pending)" 1 "op still pending"
assert_eq "$(head_att)" 1 "attempt counted"
[[ "$(head_err)" == *"HTTP 302"* ]] && ok "last_error records the redirect" || fail "last_error ($(head_err))"

echo "== 12. HTML with 200: not our API, op waits"
echo html > "$TMP/mode"
"$QUEUE" flush; rc=$?
assert_eq "$rc" 1 "flush reports API down"
assert_eq "$(pending)" 1 "op still pending"
assert_eq "$(head_att)" 2 "attempt counted"
[[ "$(head_err)" == *"non-JSON"* ]] && ok "last_error names the non-JSON body" || fail "last_error ($(head_err))"
grep -q "Traceback" "$SECONDDNS_LOG" && fail "traceback in log" || ok "no traceback"

echo "== 13. 401: retry, reported as auth rejected"
echo auth > "$TMP/mode"
"$QUEUE" flush; rc=$?
assert_eq "$rc" 1 "401 is retryable"
assert_eq "$(pending)" 1 "op still pending"
assert_eq "$(head_err)" "HTTP 401 auth rejected" "last_error text"
grep -q "API key rejected" "$SECONDDNS_LOG" && ok "log says key rejected, not API unavailable" || fail "log wording"
"$QUEUE" status --json | python3 -c "import sys,json; assert 'auth rejected' in json.load(sys.stdin)['last_error']" \
    && ok "status --json carries last_error" || fail "status --json last_error"
echo ok > "$TMP/mode"
"$QUEUE" flush >/dev/null
assert_eq "$(pending)" 0 "delivered once the key works"

echo "== 14. retry / drop failed ops"
echo badreq > "$TMP/mode"
"$QUEUE" enqueue create r1.example.com 192.0.2.10
"$QUEUE" enqueue create r2.example.com 192.0.2.10
"$QUEUE" flush >/dev/null
assert_eq "$(failed)" 2 "two failed"
id1=$(sqlite3 "$SECONDDNS_QUEUE_DB" "SELECT MIN(id) FROM ops WHERE status='failed';")
"$QUEUE" retry "$id1" >/dev/null
assert_eq "$(pending)" 1 "retry <id> requeues one"
"$QUEUE" retry --all >/dev/null
assert_eq "$(failed)" 0 "retry --all requeues the rest"
"$QUEUE" flush >/dev/null
assert_eq "$(failed)" 2 "still rejected by the API"
"$QUEUE" drop "$id1" >/dev/null
assert_eq "$(failed)" 1 "drop <id> removes one"
"$QUEUE" drop --all >/dev/null
assert_eq "$(failed)" 0 "drop --all removes the rest"
rc=0; "$QUEUE" retry abc >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 1 "retry with a bad id is refused"

echo "== 15. concurrent drainers keep FIFO"
# two flushes at once, no daemon: the lock lets only one drain
echo record > "$TMP/mode"; : > "$TMP/requests.log"
"$QUEUE" enqueue create fifo.example.com 192.0.2.10
"$QUEUE" enqueue delete fifo.example.com
"$QUEUE" flush >/dev/null & p1=$!
"$QUEUE" flush >/dev/null & p2=$!
wait $p1 $p2
assert_eq "$(pending)" 0 "drained"
assert_eq "$(sed -n 1p "$TMP/requests.log")" "POST /api/zones" "create first"
assert_eq "$(sed -n 2p "$TMP/requests.log")" "GET /api/zones/by-name/fifo.example.com" "delete second"
# daemon holding the lock during an outage: flush does not sneak in
echo down > "$TMP/mode"; : > "$TMP/requests.log"
"$QUEUE" enqueue create fifo2.example.com 192.0.2.10
"$QUEUE" enqueue delete fifo2.example.com
"$WORKER" & DPID=$!
sleep 1
out=$("$QUEUE" flush 2>&1); rc=$?
assert_eq "$rc" 0 "flush yields to the running worker"
[[ "$out" == *"another process"* ]] && ok "flush says so" || fail "flush output: $out"
echo record > "$TMP/mode"
for i in $(seq 1 15); do [ "$(pending)" = 0 ] && break; sleep 1; done
assert_eq "$(pending)" 0 "daemon drained after recovery"
assert_eq "$(sed -n 1p "$TMP/requests.log")" "POST /api/zones" "create first"
assert_eq "$(sed -n 2p "$TMP/requests.log")" "GET /api/zones/by-name/fifo2.example.com" "delete second"
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null

echo "== 16. wakeup failure is logged, not hidden"
SECONDDNS_QUEUE_SOCK="$TMP/absent.sock" "$QUEUE" enqueue create wake.example.com 192.0.2.10
grep -q "wakeup failed, worker will pick it up within 1s" "$SECONDDNS_LOG" && ok "wakeup failure logged with poll interval" || fail "wakeup log line"
echo ok > "$TMP/mode"; "$QUEUE" flush >/dev/null

echo "== 17. backoff sleep is cut short by a wakeup"
SLOWCONF="$TMP/slow.conf"; sed 's/^backoff_min = .*/backoff_min = 30/; s/^backoff_max = .*/backoff_max = 60/' "$SECONDDNS_CONF" > "$SLOWCONF"
echo down > "$TMP/mode"
"$QUEUE" enqueue create slow1.example.com 192.0.2.10
SECONDDNS_CONF="$SLOWCONF" "$WORKER" & DPID=$!
sleep 2
grep -q "retry in 30s" "$SECONDDNS_LOG" && ok "worker is in a 30s backoff" || fail "no 30s backoff in log"
echo ok > "$TMP/mode"
# a) a new enqueue wakes it
"$QUEUE" enqueue create slow2.example.com 192.0.2.10
for i in $(seq 1 8); do [ "$(pending)" = 0 ] && break; sleep 1; done
assert_eq "$(pending)" 0 "both ops delivered within ${i}s, not 30"
grep -q "woken up, retrying now" "$SECONDDNS_LOG" && ok "wakeup logged" || fail "wakeup not logged"
# b) flush while the daemon sleeps wakes it too
echo down > "$TMP/mode"
"$QUEUE" enqueue create slow3.example.com 192.0.2.10
sleep 2
echo ok > "$TMP/mode"
out=$("$QUEUE" flush 2>&1); rc=$?
assert_eq "$rc" 0 "flush yields to the worker"
[[ "$out" == *"asked it to retry now"* ]] && ok "flush sent a wakeup" || fail "flush output: $out"
for i in $(seq 1 8); do [ "$(pending)" = 0 ] && break; sleep 1; done
assert_eq "$(pending)" 0 "delivered within ${i}s after flush"
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
