#!/bin/bash
# Two writers share the queue: the worker as root, the panel's hook as the web
# user. SQLite gives -wal and -shm the mode of the database file.
# Run as root: bash hosting-panels/common/tests/test_queue_shared_access.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

[ "$(id -u)" -eq 0 ] || { echo "needs root (it switches user); skipping"; exit 0; }
command -v runuser >/dev/null || { echo "needs runuser; skipping"; exit 0; }
OTHER=nobody
OTHER_GROUP=$(id -gn "$OTHER" 2>/dev/null) || { echo "no $OTHER user; skipping"; exit 0; }

# Readable by the other user: /root is not, and a copy there fails for a
# reason that has nothing to do with what is under test.
WORK=$(mktemp -d /tmp/sdq.XXXXXX); chmod 755 "$WORK"
QUEUE="$WORK/seconddns-queue"
cp "$HERE/../seconddns-queue" "$QUEUE"; chmod 755 "$QUEUE"
trap 'rm -rf "$WORK"' EXIT

DIR="$WORK/lib"; mkdir -p "$DIR"; chgrp "$OTHER_GROUP" "$DIR"; chmod 2770 "$DIR"
export SECONDDNS_QUEUE_DB="$DIR/queue.db"
export SECONDDNS_LOG="$WORK/seconddns.log"
export SECONDDNS_CONF="$WORK/seconddns.conf"
printf 'API_KEY=x\nAPI_URL=https://example.invalid\nMASTER_IP=127.0.0.1\n' > "$SECONDDNS_CONF"
: > "$SECONDDNS_LOG"; chgrp "$OTHER_GROUP" "$SECONDDNS_LOG"; chmod 660 "$SECONDDNS_LOG"

as_other() {
    runuser -u "$OTHER" -- env SECONDDNS_QUEUE_DB="$SECONDDNS_QUEUE_DB" \
        SECONDDNS_LOG="$SECONDDNS_LOG" SECONDDNS_CONF="$SECONDDNS_CONF" \
        bash "$QUEUE" "$@" 2>&1
}

echo "== root creates the database first, as the worker does"
bash "$QUEUE" enqueue create root-first.example 127.0.0.1 >/dev/null 2>&1
mode=$(stat -c "%a" "$SECONDDNS_QUEUE_DB")
case "$mode" in
    *6?|*7?) ok "database mode $mode leaves the group writing" ;;
    *) fail "database mode $mode — the group cannot write, so neither can the hook" ;;
esac

echo "== root holds it open, so -wal and -shm exist and belong to root"
sqlite3 "$SECONDDNS_QUEUE_DB" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1
# stdin stays open, so the connection — and with it -wal and -shm — lives on
{ echo "BEGIN IMMEDIATE; SELECT 1;"; sleep 6; } | sqlite3 "$SECONDDNS_QUEUE_DB" >/dev/null 2>&1 &
sleep 1
for f in "$SECONDDNS_QUEUE_DB-wal" "$SECONDDNS_QUEUE_DB-shm"; do
    [ -e "$f" ] || continue
    m=$(stat -c "%a" "$f")
    case "$m" in
        *6?|*7?) ok "$(basename "$f") mode $m" ;;
        *) fail "$(basename "$f") mode $m — inherited from a database the group cannot write" ;;
    esac
done

echo "== and the unprivileged user can still enqueue"
out=$(as_other enqueue create other-user.example 127.0.0.1); rc=$?
if [ $rc -eq 0 ] && ! echo "$out" | grep -qi "readonly"; then
    ok "enqueue as $OTHER"
else
    fail "enqueue as $OTHER (rc=$rc): $(echo "$out" | head -2 | tr '\n' ' ')"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ $FAIL -eq 0 ]
