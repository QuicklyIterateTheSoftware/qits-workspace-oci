#!/bin/sh
# npm, pointed at the platform's two npm registries and carrying the container's credential for
# both of them.
#
# THE ADDRESSES ARE CODE, NOT CONFIGURATION. The platform's only input is QITS_DOMAIN, the bare
# public domain; the hosts and paths below are constants of the platform (qits-731), the same ones
# every other consumer derives:
#
#   * the @qits scope   — qits-artifacts' hosted npm, https://registry.qits.<domain>/artifacts/npm/npm/
#   * everything else   — qits-mirror's npmjs cache,  https://mirror.qits.<domain>/npm/npmjs/
#
# Without QITS_DOMAIN the domain is wohlben.eu, the way the qits CLI's IdpUrl falls back; never an
# internal address. Nothing injected by qits-workspaces is read: npm_config_registry is SET here,
# and overrides whatever the container was created with, so this works the same whether or not
# the service still injects one. The public names answer from inside the platform network too
# (hairpin), so one address serves a workspace and a developer host alike — which is also why a
# lockfile written here records an address that resolves everywhere, and nothing ever rewrites one.
#
# WHY A SHIM AND NOT ENVIRONMENT. npm's only spelling for a scoped registry is the config key
# `@qits:registry`, whose environment form is `npm_config_@qits:registry` — a name containing `@`
# and `:`. That name cannot travel the normal route:
#
#   * qits-containers refuses it (`Invalid environment key`), and rightly: its env keys are
#     POSIX-shaped on purpose, and widening a platform-wide validator to admit one tool's
#     convention is the wrong trade; and
#   * a shell cannot create it either — `export 'npm_config_@qits:registry=…'` is "not a valid
#     identifier" in every POSIX shell — so /etc/profile.d cannot set it, the way it does set
#     MAVEN_ARGS.
#
# A process CAN inherit such a name (measured: bash passes it through untouched and `npm config get
# @qits:registry` reads it), which is what makes `env` in the exec below work where `export` cannot.
#
# WHY NOT A .npmrc. npm ranks a PROJECT .npmrc above the user and global ones, and a repository may
# commit one naming some other registry. Only the command line and the environment outrank it, so
# nothing written to a file in HOME could win — and nothing here touches the disk at all.
#
# THE CREDENTIAL, BY THE SAME ROUTE. Both public hosts answer 401 anonymously. They accept HTTP
# Basic with the container's own commissioned client pair (QITS_COMMISSIONED_CLIENT_ID / _SECRET,
# the identity every agent container already carries), which is exactly npm's per-registry `_auth`
# (base64 of `user:password`). npm keys that by "nerf-dart", `//<host>/:_auth`, and its environment
# form `npm_config_//<host>/:_auth` is the same kind of name as the scope's — `/` and `:` in it, no
# shell can export it — so it rides the same `env` exec. npm looks a request's credential up by
# walking its URL's path back towards the host, so a host-level key covers every packument and
# tarball that host serves (a lockfile's `resolved` URLs included) and nothing on any other host:
# the credential never leaves for a registry that did not ask for it. One key per host, both
# hosts, always https.
#
# QITS_TOKEN, WHERE IT IS CARRIED, WINS OVER THE PAIR. A workspace container holds a token
# forwarded by the edge, not a pair to mint with, so there is nothing to base64: the bearer rides
# npm's per-host `//<host>/:_authToken`, the same non-exportable shape as `_auth`, carrying the
# token itself rather than `user:password`. Only one of the two keys is ever set for a host.
#
# Without either credential the registries are still set and no auth key is added; the hosts will
# then refuse, which names the missing credential rather than hiding it behind a fallback. An
# explicit `--registry` on the command line still outranks all of this, as npm intends.
qits_domain=${QITS_DOMAIN:-wohlben.eu}
qits_hosted="registry.qits.$qits_domain"
qits_proxy="mirror.qits.$qits_domain"
set -- /usr/bin/npm "$@"
if [ -n "${QITS_TOKEN:-}" ]; then
  # A workspace container carries a token forwarded by the edge, not a pair to mint with: npm's
  # per-host bearer key, `//<host>/:_authToken`, is exactly that — no base64, nothing to encode.
  set -- "npm_config_//$qits_hosted/:_authToken=$QITS_TOKEN" \
    "npm_config_//$qits_proxy/:_authToken=$QITS_TOKEN" "$@"
elif [ -n "${QITS_COMMISSIONED_CLIENT_ID:-}" ] && [ -n "${QITS_COMMISSIONED_CLIENT_SECRET:-}" ]; then
  # `tr`, not `base64 -w0`: GNU wraps at 76 columns and a long secret would put a newline in the
  # value; stripping it works on every base64 there is.
  qits_auth=$(printf '%s:%s' "$QITS_COMMISSIONED_CLIENT_ID" "$QITS_COMMISSIONED_CLIENT_SECRET" \
    | base64 | tr -d '\n')
  set -- "npm_config_//$qits_hosted/:_auth=$qits_auth" \
    "npm_config_//$qits_proxy/:_auth=$qits_auth" "$@"
fi
exec env \
  "npm_config_registry=https://$qits_proxy/npm/npmjs/" \
  "npm_config_@qits:registry=https://$qits_hosted/artifacts/npm/npm/" \
  "$@"
