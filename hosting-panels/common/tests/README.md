# Tests

Run one: `bash hosting-panels/common/tests/test_queue.sh`.
CI runs all of them on every pull request, and fails if a test here has no step
in `.github/workflows/tests.yml`.

These are integration scripts for panels we cannot run in CI, so most of them
extract the function under test out of the installer or hook and drive it
directly. That is deliberate: a test that greps the source describes it, a test
that runs it can be wrong about it.

## Three rules, each learned from a green test over broken code

### A word being present is not a criterion

Assert the property, not the mention.

`test_pdns_restart.sh` first checked that `pgrep -x pdns_server` appeared in the
installer. It does — in the *backend detection*, ten lines above. Removing the
liveness check after the restart left the test green.

`test_named_conf_edit.sh` first checked that `named-checkconf` appeared. It
does — in the message `"Check: named-checkconf"`. Replacing the actual guard
with `if true` left the test green.

Both now assert what the code does: `if named-checkconf` gating the branch, a
rollback line restoring the backup, a `did not come back` message on the path
where the service stayed down.

### GNU extensions break silently on BSD

`sed -i` without an argument, `\?`, `i\` with a leading tab — all GNU-only. On
macOS they do not error; they produce different output. The old `named.conf`
edit yielded `talso-notify` there and left a quoted `"none"` in place, on a
machine where nobody was looking.

Prefer POSIX: `sed 'script' file > tmp && cat tmp > file`, `awk` for inserts,
character classes over `\?`. A test that *runs* the code catches this. A test
that greps it cannot.

### Give every enumeration a lower bound

A check that walks a list must fail when the list comes back empty, not pass.

`TestEveryHandlerRendersHTML` looked for `sendEmail` and found 15 handlers; the
bound of 18 caught that three more send through `sendEmailNoArchive` and were
being skipped. `test_pdns_restart.sh` and `test_named_conf_edit.sh` carry
`checked >= 3` for the same reason: a rename that stops matching the installers
has to be red, not quietly green over nothing.

## Fixtures

`fixtures/cpanel-named.conf` is a real `named.conf` from a cPanel 136 server —
three views and a logging block. It is the shape that broke: an insert bounded
only by `};` lands inside logging and named stops parsing the file. Keep it as
it came off the server; a simplified copy would stop reproducing the failure.
