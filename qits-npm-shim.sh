#!/bin/sh
# npm, with the platform's @qits scope pointed at the registry that actually serves it, and the
# npm mirror's credential handed to npm for the edge that fronts it.
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
# WHY NOT A .npmrc. npm ranks a PROJECT .npmrc above the user and global ones, and every SPA here
# commits one naming the deployment host's own port — an address that does not exist inside a
# container. Only the command line and the environment outrank it, so nothing written to a file in
# HOME could win.
#
# THE MIRROR'S CREDENTIAL, BY THE SAME ROUTE. npm_config_registry — the npmjs pull-through cache,
# injected by qits-workspaces — names the mirror THROUGH THE PUBLIC EDGE now
# (https://mirror.qits.<domain>/npm/npmjs/), not its qits-net alias, and the edge wants the caller
# authenticated. It accepts HTTP Basic with the container's own commissioned client pair
# (QITS_COMMISSIONED_CLIENT_ID / _SECRET, the identity every agent container already carries), which
# is exactly npm's per-registry `_auth` (base64 of `user:password`). npm keys that per registry by
# its "nerf-dart", `//<host><path>/:_auth`, and its environment form `npm_config_//<host><path>/:_auth`
# is the same kind of name as the scope's — `/` and `:` in it, no shell can export it — so it rides
# the same `env` exec. npm matches the key as a PATH PREFIX of every request, so the packuments and
# the tarballs under that path (including a lockfile's `resolved` URLs once qits-npm-ci has swapped
# their origin) all carry it; nothing else does, so the credential never leaves for another host.
# Only over https: Basic over plain http would hand the secret to every hop, and an http registry is
# an internal alias that never asked for it.
#
# INERT UNTIL TOLD, like the Maven half: with neither the @qits address nor an https registry plus
# the commissioned pair, this execs npm with nothing added and npm behaves exactly as it always did.
# Both may apply at once; each only prepends its assignment, and there is one exec.
set -- /usr/bin/npm "$@"
if [ -n "${QITS_WORKSPACE_NPM_REGISTRY_URL:-}" ]; then
  set -- "npm_config_@qits:registry=$QITS_WORKSPACE_NPM_REGISTRY_URL" "$@"
fi
case "${npm_config_registry:-}" in
  https://*)
    if [ -n "${QITS_COMMISSIONED_CLIENT_ID:-}" ] && [ -n "${QITS_COMMISSIONED_CLIENT_SECRET:-}" ]; then
      # The nerf-dart: scheme off, query/fragment off, exactly one trailing slash.
      qits_nerf=${npm_config_registry#https://}
      qits_nerf=${qits_nerf%%[?#]*}
      qits_nerf="${qits_nerf%/}/"
      # `tr`, not `base64 -w0`: GNU wraps at 76 columns and a long secret would put a newline in the
      # value; stripping it works on every base64 there is.
      qits_auth=$(printf '%s:%s' "$QITS_COMMISSIONED_CLIENT_ID" "$QITS_COMMISSIONED_CLIENT_SECRET" \
        | base64 | tr -d '\n')
      set -- "npm_config_//$qits_nerf:_auth=$qits_auth" "$@"
    fi
    ;;
esac
exec env "$@"
