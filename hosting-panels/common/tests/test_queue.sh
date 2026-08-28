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
        elif m in ('dup','dup-other','dup-foreign'): self.reply(409, b'{"error":"exists"}')
        elif m=='badreq': self.reply(400, b'{"error":"invalid"}')
        else: self.reply(503)
    def do_GET(self):
        if self.special(): return
        m=self.mode()
        if self.path.split('?')[0]=='/api/zones' and m in ('ok','record'):
            if m=='record': self.record()
            self.reply(200, json.dumps([
                {"id":"a","name":"mine.example.com","masterIp":"192.0.2.10"},
                {"id":"b","name":"old.example.com","masterIp":"192.0.2.99"},
                {"id":"c","name":"other.example.com","masterIp":"192.0.2.99"},
                {"id":"d","name":"gone.example.com","masterIp":"192.0.2.10"}]).encode()); return
        if m in ('ok','record'):
            if m=='record': self.record()
            self.reply(200, b'{"id":"z1","masterIp":"192.0.2.10"}')
        elif m in ('owned-other','dup-other'):
            self.record(); self.reply(200, b'{"id":"z1","masterIp":"192.0.2.99"}')
        elif m in ('dup','dup-foreign'): self.reply(404)
        elif m=='noid': self.reply(200, b'{}')
        else: self.reply(503)
    def do_PATCH(self):
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        if self.special(): return
        self.record(); self.reply(200, b'{}')
    def do_DELETE(self):
        if self.special(): return
        m=self.mode()
        if m=='owned-other':
            self.record(); self.reply(204, b''); return
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

echo "== 18. worker: delete skipped when the zone is mastered elsewhere"
echo owned-other > "$TMP/mode"; : > "$TMP/requests.log"
"$QUEUE" enqueue delete moved.example.com 192.0.2.10
"$QUEUE" flush >/dev/null
assert_eq "$(pending)" 0 "op completed"
grep -q "DELETE" "$TMP/requests.log" && fail "DELETE was sent" || ok "no DELETE sent"
grep -q "mastered by 192.0.2.99, not 192.0.2.10 — delete skipped" "$SECONDDNS_LOG" && ok "skip logged with both IPs" || fail "skip not logged"
: > "$TMP/requests.log"
"$QUEUE" enqueue delete legacy.example.com
"$QUEUE" flush >/dev/null
grep -q "DELETE" "$TMP/requests.log" && ok "op without master_ip deletes as before" || fail "legacy op did not delete"
OFFCONF="$TMP/off.conf"; sed 's/^master_ip = .*/&\ndelete_check_master_ip = false/' "$SECONDDNS_CONF" > "$OFFCONF"
: > "$TMP/requests.log"
"$QUEUE" enqueue delete moved2.example.com 192.0.2.10
SECONDDNS_CONF="$OFFCONF" "$QUEUE" flush >/dev/null
grep -q "DELETE" "$TMP/requests.log" && ok "delete_check_master_ip=false deletes" || fail "check=false did not delete"

echo "== 18b. worker: create 409 names the other master"
echo dup-other > "$TMP/mode"
"$QUEUE" enqueue create moved.example.com 192.0.2.10
"$QUEUE" flush >/dev/null
assert_eq "$(pending)" 0 "409 still completes the op"
grep -q "moved.example.com exists, mastered by 192.0.2.99 not 192.0.2.10 — run seconddns-migrate-master" "$SECONDDNS_LOG" \
    && ok "log points at seconddns-migrate-master" || fail "409 log line missing"
echo dup-foreign > "$TMP/mode"
"$QUEUE" enqueue create taken.example.com 192.0.2.10
"$QUEUE" flush >/dev/null
grep -q "taken.example.com exists under another account" "$SECONDDNS_LOG" && ok "409 + by-name 404 named as another account" || fail "foreign 409 log missing"

echo "== 19. hook side: seconddns-owner"
OWNER="$HERE/../seconddns-owner"
echo ok > "$TMP/mode"
"$OWNER" x.example.com 192.0.2.10 >/dev/null; assert_eq "$?" 0 "mine -> 0"
echo owned-other > "$TMP/mode"
out=$("$OWNER" x.example.com 192.0.2.10); rc=$?
assert_eq "$rc" 1 "other master -> 1"; assert_eq "$out" "192.0.2.99" "prints the owner"
echo dup > "$TMP/mode"
"$OWNER" x.example.com 192.0.2.10 >/dev/null; assert_eq "$?" 0 "absent (404) -> 0"
echo down > "$TMP/mode"
"$OWNER" x.example.com 192.0.2.10 >/dev/null; assert_eq "$?" 2 "API down -> 2"
echo owned-other > "$TMP/mode"
SECONDDNS_CONF="$OFFCONF" "$OWNER" x.example.com 192.0.2.10 >/dev/null; assert_eq "$?" 3 "disabled in config -> 3"
NOIPCONF="$TMP/noip.conf"; grep -v '^master_ip' "$SECONDDNS_CONF" > "$NOIPCONF"
SECONDDNS_CONF="$NOIPCONF" "$OWNER" x.example.com >/dev/null; assert_eq "$?" 4 "master_ip missing in config -> 4, not 2"
( SECONDDNS_OWNER_LIB=1 . "$OWNER"; owner_check x.example.com 192.0.2.10; [ $? -eq 1 ] && [ "$OWNER_IP" = "192.0.2.99" ] ) \
    && ok "sourced: owner_check sets OWNER_IP" || fail "sourced owner_check"

echo "== 20. seconddns-migrate-master"
MIG="$HERE/../seconddns-migrate-master"
export SECONDDNS_DOMAIN_BIN="$HERE/../seconddns-domain"
printf 'mine.example.com\nOLD.example.com\nmissing.example.com\nbad_name.com\n' > "$TMP/domains.txt"
echo record > "$TMP/mode"; : > "$TMP/requests.log"
out=$("$MIG" --from-file "$TMP/domains.txt"); rc=$?
assert_eq "$rc" 0 "dry run exits 0"
grep -q "PATCH" "$TMP/requests.log" && fail "dry run sent a PATCH" || ok "dry run sends no PATCH"
[[ "$out" == *"old.example.com: 192.0.2.99 -> 192.0.2.10"* ]] && ok "plans old.example.com" || fail "plan missing: $out"
[[ "$out" == *"1 to change, 1 already 192.0.2.10, 1 not in SecondDNS, 1 invalid"* ]] && ok "summary counts" || fail "summary: $out"
: > "$TMP/requests.log"
"$MIG" --from-file "$TMP/domains.txt" --apply >/dev/null; rc=$?
assert_eq "$rc" 0 "apply exits 0"
assert_eq "$(grep -c PATCH "$TMP/requests.log")" 1 "apply sends exactly one PATCH"
grep -q "PATCH /api/zones/b" "$TMP/requests.log" && ok "PATCH hits the moved zone" || fail "wrong PATCH target"
: > "$TMP/requests.log"
"$MIG" --from-file "$TMP/domains.txt" --master-ip 192.0.2.77 --apply >/dev/null
assert_eq "$(grep -c PATCH "$TMP/requests.log")" 2 "--master-ip overrides config (both zones differ now)"
: > "$TMP/requests.log"
"$MIG" --all --apply >/dev/null
assert_eq "$(grep -c PATCH "$TMP/requests.log")" 2 "--all reaches zones not on this panel"
grep -q "PATCH /api/zones/c" "$TMP/requests.log" && ok "other.example.com included with --all" || fail "--all missed c"

echo "== 21. seconddns-reconcile"
REC="$HERE/../seconddns-reconcile"; export SECONDDNS_QUEUE_BIN="$QUEUE"
sqlite3 "$SECONDDNS_QUEUE_DB" "DELETE FROM ops;"
echo ok > "$TMP/mode"
out=$("$REC" --from-file "$TMP/domains.txt"); rc=$?
assert_eq "$rc" 0 "report exits 0"
[[ "$out" == *"ok: 1   missing: 1   stale: 2 (1 mine, 1 mastered elsewhere)   master mismatch: 1"* ]] && ok "report counts" || fail "report: $out"
[[ "$out" == *"mismatch: old.example.com  mastered by 192.0.2.99"* ]] && ok "mismatch points at migrate-master" || fail "mismatch line"
out=$("$REC" --from-file "$TMP/domains.txt" --add-missing --remove-stale)
assert_eq "$(pending)" 0 "dry run queues nothing"
[[ "$out" == *"[DRY RUN] create missing.example.com"* && "$out" == *"[DRY RUN] delete gone.example.com"* ]] && ok "dry run lists both operations" || fail "dry run: $out"
[[ "$out" == *"delete other.example.com  [skipped: mastered by 192.0.2.99]"* ]] && ok "foreign stale skipped in dry run" || fail "foreign stale: $out"
"$REC" --from-file "$TMP/domains.txt" --add-missing --apply >/dev/null
assert_eq "$(sqlite3 "$SECONDDNS_QUEUE_DB" "SELECT op||' '||domain||' '||IFNULL(master_ip,'') FROM ops;")" "create missing.example.com 192.0.2.10" "--add-missing --apply queues the create"
sqlite3 "$SECONDDNS_QUEUE_DB" "DELETE FROM ops;"
"$REC" --from-file "$TMP/domains.txt" --remove-stale --apply >/dev/null
assert_eq "$(sqlite3 "$SECONDDNS_QUEUE_DB" "SELECT op||' '||domain||' '||IFNULL(master_ip,'') FROM ops;")" "delete gone.example.com 192.0.2.10" "--remove-stale --apply queues only the own-master stale"
sqlite3 "$SECONDDNS_QUEUE_DB" "DELETE FROM ops;"
# panel cannot be read -> refusal, nothing queued
rc=0; SECONDDNS_PANEL_ZONES_CMD="false" "$REC" --remove-stale --apply >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 1 "panel command failing -> exit 1"
assert_eq "$(pending)" 0 "and nothing queued"
rc=0; SECONDDNS_PANEL_ZONES_CMD="true" "$REC" --remove-stale --apply >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 1 "panel reporting no zones -> exit 1"
: > "$TMP/empty.txt"
rc=0; "$REC" --from-file "$TMP/empty.txt" --remove-stale --apply >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 1 "empty --from-file -> exit 1"
assert_eq "$(pending)" 0 "still nothing queued"
# panel zone list is what counts: a zone list from the panel, not sites
out=$(SECONDDNS_PANEL_ZONES_CMD="printf 'mine.example.com\nold.example.com\n'" "$REC")
[[ "$out" == *"ok: 1   missing: 0   stale: 2"* ]] && ok "panel zone list drives the report" || fail "panel cmd report: $out"
# bulk delete threshold: a list without any of my zones would drop all of them
printf 'old.example.com\n' > "$TMP/wrong.txt"
rc=0; out=$("$REC" --from-file "$TMP/wrong.txt" --remove-stale --apply 2>&1) || rc=$?
assert_eq "$rc" 1 "deleting all own zones is refused"
[[ "$out" == *"would delete 2 of 2"* ]] && ok "refusal names the numbers" || fail "refusal text: $out"
assert_eq "$(pending)" 0 "refusal queues nothing"
"$REC" --from-file "$TMP/wrong.txt" --remove-stale --apply --force-bulk-delete >/dev/null
assert_eq "$(pending)" 2 "--force-bulk-delete overrides"
sqlite3 "$SECONDDNS_QUEUE_DB" "DELETE FROM ops;"
# piped into a reader that closes without reading: no traceback on stderr
err=$( { "$REC" --from-file "$TMP/domains.txt" | true; } 2>&1 )
[[ "$err" == *"BrokenPipe"* ]] && fail "BrokenPipeError when the reader closes the pipe" || ok "no traceback when the reader closes the pipe"
err=$( { "$MIG" --from-file "$TMP/domains.txt" | true; } 2>&1 )
[[ "$err" == *"BrokenPipe"* ]] && fail "migrate-master: BrokenPipeError" || ok "migrate-master: no traceback either"
unset SECONDDNS_QUEUE_BIN SECONDDNS_DOMAIN_BIN

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
