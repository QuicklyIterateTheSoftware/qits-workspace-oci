# /etc/qits/init.d/50-egress.sh (epic qits-2525, qits-2657): agents reach outside resources only
# through qits-egress.
#
# SOURCED, NOT RUN, by qits-trust-init (qits-build-images-oci, qits-2656) just before it execs the
# daemon: each /etc/qits/init.d/*.sh runs in a guarded subshell whose `export -p` is carried back, so
# the exports below reach the daemon and everything it launches. POSIX sh — it runs under dash.
#
# It starts `qits egress forward --listen 127.0.0.1:3128` in a restart loop: the CLI accepts TCP on
# that port and carries each connection over a websocket through the edge to qits-egress's proxy
# listener, which no runner-placed container can reach directly. Then it points every HTTP client at
# it: HTTPS_PROXY/HTTP_PROXY in both spellings, NODE_USE_ENV_PROXY for node's fetch, and the JVM's
# proxy properties in JDK_JAVA_OPTIONS (read by the `java` launcher only, so native binaries and
# other JVM embedders are untouched). NO_PROXY keeps loopback, the platform's own hosts and private
# ranges direct.
#
# IT EXPORTS NOTHING UNLESS THE PROXY IS REALLY THERE, because a proxy variable pointing at a dead
# listener cuts a container off from everything outside it:
#   - QITS_EGRESS=off (the creator's kill switch), no QITS_DOMAIN, or no `qits` on PATH: nothing at
#     all, silently.
#   - no platform trust anchor: qits-trust-init (the same exec that sources this directory, just
#     before it does) writes $QITS_TRUST_DIR/anchors.pem (default /etc/ssl/qits;
#     qits-build-images-oci's trust/qits-trust-layout and trust/qits-trust-init), and it stays empty
#     unless the container was started with QITS_TRUST_ANCHORS. qits-egress fronts some hosts with a
#     platform-CA leaf, so a container with no anchor and the proxy on fails those hosts' TLS with
#     SELF_SIGNED_CERT_IN_CHAIN instead (the live outage qits-2525 fixes) — one stderr line, nothing
#     started, nothing exported.
#   - a `qits` without `egress forward` (an image built on an older CLI pin): one stderr line,
#     nothing started, nothing exported. The exit status alone does not tell: picocli answers an
#     unknown subcommand followed by --help with the TOP-LEVEL usage and exit 0 (measured on
#     qits-platform-access-cli 2026.1125.25906), so the guard also requires the command's own
#     `Usage: qits egress forward` line.
#   - a listener that does not accept within ~3 s: one stderr line, nothing exported. The loop keeps
#     trying in the background; only this start's environment goes without the proxy.
#
# The loop's stdin, stdout, stderr and fd 3 (qits-trust-init's channel for `export -p`) are detached
# from the init, so it holds none of the start's descriptors open. The readiness probe is bash's
# /dev/tcp (bash is installed by this image's Dockerfile; dash has no such thing).
if [ "${QITS_EGRESS:-on}" != off ] && [ -n "${QITS_DOMAIN:-}" ] && command -v qits >/dev/null 2>&1; then
  _td=${QITS_TRUST_DIR:-/etc/ssl/qits}
  if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$_td/anchors.pem" 2>/dev/null; then
    echo "qits-egress-hook: no platform trust anchor, the proxy stays off" >&2
  else
    _h=$(qits egress forward --help 2>/dev/null) || _h=''
    case "$_h" in *"Usage: qits egress forward"*) _h=1 ;; *) _h='' ;; esac
    if [ -z "$_h" ]; then
      echo "qits-egress: the installed qits CLI has no 'egress forward'; no egress proxy for this container" >&2
    else
      ( while :; do qits egress forward --listen 127.0.0.1:3128 >>/tmp/qits-egress-forward.log 2>&1; sleep 2; done ) \
        </dev/null >/dev/null 2>&1 3>&- &
      _up=''
      _i=0
      while [ "$_i" -lt 30 ]; do
        if bash -c ': </dev/tcp/127.0.0.1/3128' >/dev/null 2>&1; then _up=1; break; fi
        sleep 0.1
        _i=$((_i + 1))
      done
      if [ -z "$_up" ]; then
        echo "qits-egress: 'qits egress forward' is not accepting on 127.0.0.1:3128 after 3 s (see /tmp/qits-egress-forward.log); no egress proxy for this start" >&2
      else
        QITS_EGRESS_PROXY=127.0.0.1:3128
        _p="http://$QITS_EGRESS_PROXY"
        _n="localhost,127.0.0.1,::1,.qits.$QITS_DOMAIN,host.docker.internal,100.96.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10"
        export QITS_EGRESS_PROXY HTTPS_PROXY="$_p" https_proxy="$_p" HTTP_PROXY="$_p" http_proxy="$_p" NO_PROXY="$_n" no_proxy="$_n" NODE_USE_ENV_PROXY=1
        export JDK_JAVA_OPTIONS="${JDK_JAVA_OPTIONS:+$JDK_JAVA_OPTIONS }-Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=3128 -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=3128 -Dhttp.nonProxyHosts=localhost|127.*|10.*|172.*|192.168.*|100.*|*.qits.$QITS_DOMAIN|host.docker.internal"
        unset _p _n
      fi
      unset _up _i
    fi
    unset _h
  fi
  unset _td
fi
# The hook's status is the guard's verdict: a non-zero one makes qits-trust-init discard every export.
:
