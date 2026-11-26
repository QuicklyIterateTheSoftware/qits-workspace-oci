#!/bin/sh
# THE EGRESS HOOK TEST (epic qits-2525, qits-2657): proves /etc/qits/init.d/50-egress.sh
# (qits-egress-hook.sh here) through the real qits-trust-init, with a stub `qits` first on PATH that
# records its argv and plays one of three CLIs:
#
#   listen  has `egress forward` and really listens on the --listen address (a python3 socket)
#   old     an older CLI as it really answers (2026.1125.25906): `egress forward --help` prints the
#           TOP-LEVEL usage and exits 0, and `egress forward --listen ...` is unmatched
#   unknown an older CLI that exits 2 on the unknown subcommand
#   dead    has `egress forward`, but the forwarder exits at once and never listens
#
# It asserts, from what `qits-trust-init env` prints:
#   - listen: the stub was started with `egress forward --listen 127.0.0.1:3128`, every export has
#     exactly the dossier's value (JDK_JAVA_OPTIONS appended to, not replaced), the init is quiet,
#     and the forwarder outlives the init (it is still accepting after `env` exited);
#   - old, unknown: nothing started, nothing exported, one stderr line;
#   - dead: nothing exported after the ~3 s wait, one stderr line;
#   - QITS_EGRESS=off, and no QITS_DOMAIN: nothing started, nothing exported, nothing on stderr.
#
#   sh test-egress-hook.sh <qits-trust-init>   simulate: that qits-trust-init (a checkout of
#                                              qits-build-images-oci's trust/qits-trust-init) and the
#                                              hook from this directory, in a temp hook dir. No root,
#                                              no docker; QITS_TRUST_DIR points at a path that does not
#                                              exist, so the machine's own trust store is never touched.
#   sh test-egress-hook.sh --installed          inside the built image (the Dockerfile's `check`
#                                              target): /usr/local/bin/qits-trust-init and the real
#                                              /etc/qits/init.d.
#
# Needs bash, python3 and setsid (each run is its own session, so the restart loop it leaves behind
# is killed as one process group). The hook's listen address is fixed, so 127.0.0.1:3128 must be free.
set -u

failures=0
pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1" >&2; failures=$((failures + 1)); }

for tool in bash python3 setsid; do
  command -v "$tool" >/dev/null 2>&1 || { echo "test-egress-hook: $tool is required" >&2; exit 2; }
done
listening() { bash -c ': </dev/tcp/127.0.0.1/3128' >/dev/null 2>&1; }
if listening; then
  echo "test-egress-hook: something already accepts on 127.0.0.1:3128; the hook's port must be free" >&2
  exit 2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-egress-hook.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM

if [ "${1:-}" = --installed ]; then
  init=/usr/local/bin/qits-trust-init
  hookdir=/etc/qits/init.d
  trustdir=''
  hook=$hookdir/50-egress.sh
  if [ -f "$hook" ] && [ -r "$hook" ]; then pass "$hook is installed and readable"; else fail "$hook is missing or unreadable"; fi
  # The image's label promises a working hook, so the two things it rests on are part of the image
  # contract: a qits-trust-init that sources /etc/qits/init.d (node-browser-base 2026.1125.234117 on,
  # qits-2656) and a pinned CLI that has `egress forward` (qits-platform-access-cli 2026.1126.33114 on).
  if grep -q QITS_INIT_HOOK_DIR "$init"; then
    pass "qits-trust-init sources /etc/qits/init.d"
  else
    fail "$init sources no /etc/qits/init.d hooks: BROWSER_BASE predates qits-2656"
  fi
  if /usr/local/bin/qits egress forward --help 2>/dev/null | grep -q 'Usage: qits egress forward'; then
    pass "the pinned qits CLI has 'egress forward'"
  else
    fail "the pinned qits CLI ($(cat /etc/qits-cli-version 2>/dev/null)) has no 'egress forward': pom.xml's CLI pin predates it"
  fi
else
  init=${1:?usage: test-egress-hook.sh <path to qits-trust-init> | --installed}
  here=$(cd "$(dirname "$0")" && pwd)
  hookdir=$tmp/init.d
  trustdir=$tmp/no-trust-dir
  mkdir -p "$hookdir"
  cp "$here/qits-egress-hook.sh" "$hookdir/50-egress.sh"
  hook=$hookdir/50-egress.sh
fi
if sh -n "$hook"; then pass "the hook parses as POSIX sh"; else fail "the hook does not parse"; fi

# THE STUB. Its state directory is baked in, because the runs below start from a cleaned environment.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/qits" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/argv"
mode=\$(cat "$tmp/mode")
[ "\${1:-} \${2:-}" = "egress forward" ] || exit 0
case "\$mode" in
  old) if [ "\${3:-}" = --help ]; then echo 'Usage: qits [-hV] [COMMAND]'; exit 0; fi
       echo "Unmatched arguments from index 0: 'egress', 'forward'" >&2; exit 0 ;;
  unknown) echo "Unmatched argument at index 1: 'forward'" >&2; exit 2 ;;
esac
if [ "\${3:-}" = --help ]; then echo 'Usage: qits egress forward [-hV] [--listen=<host:port>] [--url=<wss url>]'; exit 0; fi
[ "\$mode" = dead ] && exit 1
[ "\${3:-}" = --listen ] || exit 2
exec python3 -c '
import socket, sys
host, port = sys.argv[1].rsplit(":", 1)
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((host, int(port)))
s.listen(16)
while True:
    c, _ = s.accept()
    c.close()
' "\$4"
STUB
chmod 0755 "$tmp/bin/qits"

# One start: `qits-trust-init env` in a session of its own, from an environment with none of the
# variables the hook writes. Prints nothing; leaves $tmp/out, $tmp/err, $tmp/argv and, in $tmp/alive,
# whether the forwarder still accepted once `env` had exited. Then kills whatever the start left.
start() {
  mode=$1
  shift
  echo "$mode" >"$tmp/mode"
  : >"$tmp/argv"
  rm -f "$tmp/pgid"
  setsid -w env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u NO_PROXY -u no_proxy \
      -u NODE_USE_ENV_PROXY -u QITS_EGRESS_PROXY -u JDK_JAVA_OPTIONS -u QITS_EGRESS -u QITS_DOMAIN \
      -u QITS_TRUST_ANCHORS ${trustdir:+QITS_TRUST_DIR=$trustdir} \
      QITS_INIT_HOOK_DIR="$hookdir" PATH="$tmp/bin:$PATH" "$@" \
      sh -c 'echo $$ >"$0"; exec sh "$1" env' "$tmp/pgid" "$init" >"$tmp/out" 2>"$tmp/err"
  if listening; then echo yes >"$tmp/alive"; else echo no >"$tmp/alive"; fi
  if [ -s "$tmp/pgid" ]; then kill -TERM -"$(cat "$tmp/pgid")" 2>/dev/null; fi
  i=0
  while listening && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}
exported() { grep -E '^(HTTPS_PROXY|https_proxy|HTTP_PROXY|http_proxy|NO_PROXY|no_proxy|NODE_USE_ENV_PROXY|QITS_EGRESS_PROXY|JDK_JAVA_OPTIONS)=' "$tmp/out"; }
has_line() { grep -qxF -- "$1" "$2"; }
lines() { if [ -s "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

domain=example.test
proxy=http://127.0.0.1:3128
no_proxy_list="localhost,127.0.0.1,::1,.qits.$domain,host.docker.internal,100.96.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10"
jvm="-Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=3128 -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=3128 -Dhttp.nonProxyHosts=localhost|127.*|10.*|172.*|192.168.*|100.*|*.qits.$domain|host.docker.internal"

# 1. The happy path: a CLI with `egress forward` that listens.
start listen QITS_DOMAIN="$domain"
if has_line 'egress forward --listen 127.0.0.1:3128' "$tmp/argv"; then
  pass "listen: the stub was started with 'egress forward --listen 127.0.0.1:3128'"
else
  fail "listen: the stub's argv was '$(tr '\n' ';' <"$tmp/argv")'"
fi
if has_line 'egress forward --help' "$tmp/argv"; then pass "listen: the CLI was asked for 'egress forward --help' first"; else fail "listen: no 'egress forward --help' guard call"; fi
for pair in "QITS_EGRESS_PROXY=127.0.0.1:3128" "HTTPS_PROXY=$proxy" "https_proxy=$proxy" "HTTP_PROXY=$proxy" \
    "http_proxy=$proxy" "NO_PROXY=$no_proxy_list" "no_proxy=$no_proxy_list" "NODE_USE_ENV_PROXY=1" \
    "JDK_JAVA_OPTIONS=$jvm"; do
  if has_line "$pair" "$tmp/out"; then pass "listen: exports ${pair%%=*}"; else fail "listen: ${pair%%=*} is '$(grep "^${pair%%=*}=" "$tmp/out")'"; fi
done
if [ "$(lines "$tmp/err")" = 0 ]; then pass "listen: the init is quiet"; else fail "listen: stderr '$(cat "$tmp/err")'"; fi
if [ "$(cat "$tmp/alive")" = yes ]; then pass "listen: the forwarder outlives the init"; else fail "listen: nothing accepts on 127.0.0.1:3128 once the init exec'd"; fi
if grep -qE '^(_h|_p|_n|_up|_i)=' "$tmp/out"; then fail "listen: the hook leaked a helper variable"; else pass "listen: no helper variable leaks"; fi

# 2. JDK_JAVA_OPTIONS a creator already set is appended to, not replaced.
start listen QITS_DOMAIN="$domain" JDK_JAVA_OPTIONS=-Dcreator=1
if has_line "JDK_JAVA_OPTIONS=-Dcreator=1 $jvm" "$tmp/out"; then
  pass "listen: JDK_JAVA_OPTIONS is appended to"
else
  fail "listen: JDK_JAVA_OPTIONS is '$(grep '^JDK_JAVA_OPTIONS=' "$tmp/out")'"
fi

# 3. An older CLI, without `egress forward`, both ways it can answer: the guard keeps every proxy
# variable out.
for mode in old unknown; do
  start "$mode" QITS_DOMAIN="$domain"
  if [ -z "$(exported)" ]; then pass "$mode CLI: nothing exported"; else fail "$mode CLI: exported $(exported | tr '\n' ' ')"; fi
  if grep -q -- '--listen' "$tmp/argv"; then fail "$mode CLI: the forwarder was started anyway"; else pass "$mode CLI: no forwarder started"; fi
  if [ "$(lines "$tmp/err")" = 1 ] && grep -q 'egress forward' "$tmp/err"; then pass "$mode CLI: one stderr line"; else fail "$mode CLI: stderr '$(cat "$tmp/err")'"; fi
done

# 4. A forwarder that never listens: after the wait, one line and nothing exported.
start dead QITS_DOMAIN="$domain"
if grep -q -- 'egress forward --listen 127.0.0.1:3128' "$tmp/argv"; then pass "dead listener: the forwarder was started"; else fail "dead listener: the forwarder was never started"; fi
if [ -z "$(exported)" ]; then pass "dead listener: nothing exported"; else fail "dead listener: exported $(exported | tr '\n' ' ')"; fi
if [ "$(lines "$tmp/err")" = 1 ] && grep -q '127.0.0.1:3128' "$tmp/err"; then pass "dead listener: one stderr line"; else fail "dead listener: stderr '$(cat "$tmp/err")'"; fi

# 5. The kill switch, and a container with no QITS_DOMAIN: nothing at all, silently.
start listen QITS_DOMAIN="$domain" QITS_EGRESS=off
if [ -z "$(exported)" ] && ! [ -s "$tmp/argv" ] && [ "$(lines "$tmp/err")" = 0 ]; then
  pass "QITS_EGRESS=off: nothing started, nothing exported, quiet"
else
  fail "QITS_EGRESS=off: exported '$(exported | tr '\n' ' ')', argv '$(tr '\n' ';' <"$tmp/argv")', stderr '$(cat "$tmp/err")'"
fi
start listen
if [ -z "$(exported)" ] && ! [ -s "$tmp/argv" ] && [ "$(lines "$tmp/err")" = 0 ]; then
  pass "no QITS_DOMAIN: nothing started, nothing exported, quiet"
else
  fail "no QITS_DOMAIN: exported '$(exported | tr '\n' ' ')', argv '$(tr '\n' ';' <"$tmp/argv")', stderr '$(cat "$tmp/err")'"
fi

if [ "$failures" -gt 0 ]; then
  echo "test-egress-hook: $failures failure(s)" >&2
  exit 1
fi
echo "test-egress-hook: all passed"
