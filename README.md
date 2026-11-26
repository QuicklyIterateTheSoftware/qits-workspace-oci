# qits-workspace-oci

The workspace toolchain base image, published as **`qits/workspace-base`**.

It holds the tools a workspace container needs to work on a checkout: git and a shell toolchain,
JDK 25, node + pnpm, python, a pinned Playwright Chromium with a pinned font stack, the coding agent
CLIs (Claude Code, Kimi Code), language servers (jdtls, typescript-language-server), and the docker
**client**. Every package is commented in the `Dockerfile` with the reason it is there. Read that
before changing anything.

Node and the screenshot renderer (Playwright Chromium and the fonts) come from the base image,
`qits/build-images/node-browser-base`, pinned in the `BROWSER_BASE` line. CI's `app` QA step runs
browser screenshot tests on that same image, so baselines regenerated in a workspace match CI. Change
the renderer there, never here.

The coding agent also gets a browser it drives: `qits-browser-mcp` starts Microsoft's Playwright MCP
server (`@playwright/mcp`, `PLAYWRIGHT_MCP_VERSION`) headless on the base's Chromium, with an
in-memory profile and its files under `/tmp/playwright-mcp`. qits-workspace-daemon attaches it to
every Claude launch as the MCP server `browser`. The build fails when `PLAYWRIGHT_MCP_VERSION` is
built on another Playwright major.minor than the base bakes.

The docker CLI is the one that looks alarming and is not: it is `docker-ce-cli` alone — no daemon,
no socket — and a workspace container reaches nothing with it unless it was created in **admin
mode**, the per-workspace posture that makes qits-containers bind the host's socket into it. In
every other workspace `docker ps` answers "Cannot connect to the Docker daemon", which is the honest
state. The privilege is the bind, which only the platform grants; this is the client that has
something to say once it exists.

It carries no daemon binary and no entrypoint. It is a base, not a runnable workspace.

## What consumes it

`qits-workspace-daemon`'s `docker/Dockerfile` builds its native binary and layers it onto this
image in one build — the final stage's `FROM` pins a released version of this repository, and the
pin is bumped by the train (`ci-event-upstream-oci-workspace.yml` there) whenever this repository
releases. That result is the image a workspace container runs. The project-agent images follow the
same shape for their own binary.

The published name is `qits/workspace-base`, not the repository name, because that is the name those
Dockerfiles already write.

## What a workspace gets from it besides tools

### `qits` — the platform's own command line

On PATH as `qits`, **pinned** at the version in `pom.xml`'s `qits.platform-access-cli-binary.version`
property (also written to `/etc/qits-cli-version`, so a container can answer the question about
itself; the Dockerfile takes it as a build arg with no default). It is what an agent
should reach for first: projects and repositories, tickets, epics, release requests, CI runs and
their logs, domain events, live telemetry, and `qits artifacts publish` from a CI step.

**There is no login.** Inside a container the CLI signs itself in from the `QITS_TOKEN`
qits-workspaces injects, so it acts as the container's **own agent identity** and never as the
operator. That identity reads: the
reads work, and a write only an operator may make answers **403**. A 403 from `qits` is the platform
saying "not this identity", not a broken install.

The version is pinned into the image rather than downloaded when a container starts, so a container
always runs the version its image was built with and starts with no download and no store to be
reachable.

**The pin is an ordinary maven dependency**, and this repository has a `pom.xml` for no other reason
— it publishes no jar and compiles nothing. The dependency is
`eu.wohlben.qits:qits-platform-access-cli-binary` at the property
`qits.platform-access-cli-binary.version`; that artifact is a handful of strings published by the
same `qits-platform-access-cli` release that publishes the 42 MB binary, so its version *is* the
daemons-store coordinate. qits-ci pins it the same way and spells the property identically.

**Moving the pin** is therefore not something you do: qits-platform-maintenance bumps that line on a
`maintenance/*` branch like any other internal pin, this repository's own release request gates the
move, and the consuming images (`qits-workspace-daemon`, the editor and project-agent images) take
the new base. That is the same path every other pin here travels, and it is the point — as an
`ARG QITS_CLI_VERSION=` line the pin was bumped by nothing and kept alive in the store by nothing, so
it rotted on a clock and killed the release pipeline with a 404 twice in three days. `pom.xml`'s
comment and the `Dockerfile` block at the foot of the file carry the argument.

The binary is **not fetched by the Dockerfile**. This build dials nothing on the platform, and the
artifacts store is not anonymous, so the CI **step** container — which holds the run's own
`QITS_TOKEN` and the store's address — fetches the file into the build context and the Dockerfile only `COPY`s it.
Both recipes in `.config/qits/release.yml` carry that fetch, byte for byte identical; both read the
version out of the pom property and pass it to buildctl as `--opt build-arg:QITS_CLI_VERSION=`, and
both run `./mvnw -B -ntp verify` first, which resolves the pinned jar and does nothing else — so a pin
the maven registry no longer holds fails there, naming the coordinate, rather than as a bare 404 from
the `curl` much later. The `Dockerfile` block at the foot of the file has the full reasoning,
including why it sits last.

### Two shell helpers, older than the CLI and not retired by it

Both inert until qits-workspaces injects `QITS_TOKEN` — a runner-placed workspace container's own
opaque `qits_tok_` token, and an admin or editor workspace container's too, even though those stay
DIRECT-placed on qits-containers. They answer straight from it and never mint: there is nothing to
mint, since `QITS_TOKEN` already works as a bearer — presented to the public edge, it is
introspected there and a short `qits-platform` JWT is forwarded on to the service behind.

- `qits-git-credential` — git's credential helper, answering the injected githost authority with
  `username=oauth2` and the token as `password=` (and nothing else: a checkout can name arbitrary
  submodule remotes). Silent and exit 0 on every failure, a missing token included, so git falls
  through to its next helper.
- `qits-token` — the same token, for the hands that are not git: qits-projects' release
  requests, the ci run list, any platform API. It prints `QITS_TOKEN` outright; there is only one
  audience, `qits-platform`, so it takes no argument (an old caller's audience positional is still
  accepted and ignored). Loud on failure (exit 1 without a token), unlike the git helper, since a
  person or an agent calling it needs to know why.

`npm` itself is a shim that points npm at the platform's registries and authenticates to them.
`npx` is the same shim, installed a second time as a symlink, so an `npx` that has to fetch a
package authenticates exactly the same way instead of falling through to the real, uncredentialed
binary underneath (qits-2254). The addresses are code plus `QITS_DOMAIN` (falling back to
`wohlben.eu`), never injected URLs: the `@qits` scope at
`https://registry.qits.<domain>/artifacts/npm/npm/` and everything else through the npmjs cache at
`https://mirror.qits.<domain>/npm/npmjs/`. With `QITS_TOKEN` set it carries that as a per-host
`_authToken` for both hosts; without it no auth key is added and the hosts refuse (see the shim's
header). A lockfile written against those names resolves everywhere, so a plain `npm ci` works and
nothing rewrites a lockfile. A workspace never needs a token file for any of this: no `~/.npmrc`
(`HOME` is shared across every agent container, qits-1918) and no `NPM_CONFIG_USERCONFIG` pointing
somewhere else — `npm` and `npx` on `PATH` already carry the credential.

Plus `/etc/profile.d/qits-workspace.sh` for every login shell: a passwd entry for the arbitrary uid,
and the Maven settings that send the `qits-maven` repository to
`https://registry.qits.<domain>/artifacts/maven/maven` and Maven Central through the cache at
`https://mirror.qits.<domain>/mirror/maven/central`. With `QITS_TOKEN` set the profile applies
`/etc/qits/maven-settings-token.xml`, whose two `<server>` entries carry the token as an
`Authorization: Bearer` header and no username or password; without it no settings are applied and
Maven stays on stock Maven Central. A caller that already passes its own `-s`/`--settings` keeps it
either way. The profile derives the two mirror URLs from `QITS_DOMAIN` and exports them for the
settings file to read; nothing injects them.

### The egress init hook — `/etc/qits/init.d/50-egress.sh`

Epic qits-2525: agents reach outside resources only through qits-egress. `qits-trust-init`, the
ENTRYPOINT of the workspace, agents and projects daemon images built on this one, sources every
`/etc/qits/init.d/*.sh` just before it execs the daemon (qits-build-images-oci, qits-2656), so a
hook's exports reach the daemon and everything it launches. This image installs one,
`qits-egress-hook.sh`, and carries the label `eu.wohlben.qits.egress-hook="1"`.

When `QITS_EGRESS` is not `off`, `QITS_DOMAIN` is set, `qits` is on PATH and the platform trust
anchor is present, the hook:

1. Asks `qits egress forward --help` and requires the command's own `Usage: qits egress forward`
   line. The exit status alone does not tell: an older CLI answers an unknown subcommand followed
   by `--help` with its top-level usage and exit 0. Without the command it logs one stderr line
   and stops.
2. Starts `qits egress forward --listen 127.0.0.1:3128` in a restart loop (2 s between runs),
   logging to `/tmp/qits-egress-forward.log`, with every descriptor of the init detached.
3. Waits up to 3 s for 127.0.0.1:3128 to accept (bash's `/dev/tcp`). If it never does, it logs
   one stderr line and exports nothing. The loop keeps trying in the background.
4. Exports `QITS_EGRESS_PROXY=127.0.0.1:3128`, `HTTPS_PROXY`/`https_proxy`/`HTTP_PROXY`/`http_proxy`
   `=http://127.0.0.1:3128`, `NO_PROXY`/`no_proxy` (loopback, `.qits.<domain>`,
   `host.docker.internal`, `100.96.0.1` and the private ranges), `NODE_USE_ENV_PROXY=1`, and
   appends the JVM's proxy properties to `JDK_JAVA_OPTIONS`.

It exports nothing unless the proxy is really there, because a proxy variable that names a dead
listener cuts the container off from everything outside it. `QITS_EGRESS=off` is the creator's kill
switch.

**The platform trust anchor is a precondition, not an afterthought.** `qits-trust-init` runs this
hook *after* it has already rewritten `$QITS_TRUST_DIR/anchors.pem` (default `/etc/ssl/qits`,
qits-build-images-oci's `trust/qits-trust-layout` and `trust/qits-trust-init`) from
`QITS_TRUST_ANCHORS`, so by the time the hook runs that file already says whether this container's
start carried the anchor. The hook checks it is present and holds at least one
`-----BEGIN CERTIFICATE-----` block before doing anything else. A container started without
`QITS_TRUST_ANCHORS` has a 0-byte `anchors.pem` — the hook logs
`qits-egress-hook: no platform trust anchor, the proxy stays off` to stderr and exports nothing,
starting no forwarder. Skipping this check was a live outage: qits-egress fronts some hosts with a
platform-CA leaf, so a container with the proxy on but no anchor in its trust store failed those
hosts' TLS with `SELF_SIGNED_CERT_IN_CHAIN` (qits-2525).

The label is a promise. qits-system-runner hands the Claude login over to qits-egress only when every
container that mounts the credential volume runs an image that carries it. So the image must never
carry the label where the hook cannot work.

**The check is `test-egress-hook.sh`.** It runs the real `qits-trust-init` with a stub `qits` first
on PATH. It covers the happy path (the stub's argv, every exported value, `JDK_JAVA_OPTIONS`
appended to, the forwarder outliving the init), an older CLI answered both ways, a listener that
never comes up, a missing or empty `anchors.pem`, `QITS_EGRESS=off`, and no `QITS_DOMAIN`. The
happy-path and CLI/listener cases mint one throwaway self-signed certificate with `openssl` and pass
it as `QITS_TRUST_ANCHORS` so the real `qits-trust-init` populates `anchors.pem` exactly as a
container start would; the missing/empty cases run with no anchor at all, or with the anchor that an
earlier case's `QITS_TRUST_ANCHORS` populated now reset back to empty by `qits-trust-init`'s own
`reset_public` — the same way a plain start without the variable always resets it. The Dockerfile's
`check` target runs it with `--installed` as `nobody`, and both release recipes build that target
before the image. In installed mode it also fails when the base's `qits-trust-init` sources no hooks
(`BROWSER_BASE` older than node-browser-base 2026.1125.234117) or the pinned CLI has no
`egress forward` (older than qits-platform-access-cli 2026.1126.33114). To run it without docker,
against a checkout of qits-build-images-oci (needs bash, python3, setsid, openssl and a free port
3128):

    sh test-egress-hook.sh ../../qits-build-images/qits-build-images-oci/trust/qits-trust-init

## Building by hand

**Fetch the `qits` binary into the context first**, or the `COPY` fails: the Dockerfile expects the
file the CI step puts there, and nothing inside the build can fetch it — the builder holds no
platform credential and the recipe hands it no platform address. With a `qits-platform` bearer in
`$token`:

    version=$(sed -nE 's#^[[:space:]]*<qits\.platform-access-cli-binary\.version>(.+)</qits\.platform-access-cli-binary\.version>[[:space:]]*$#\1#p' pom.xml)
    qits_domain=${QITS_DOMAIN:-wohlben.eu}
    curl -fsSL -H "Authorization: Bearer $token" \
      -o qits "https://registry.qits.$qits_domain/artifacts/daemons/qits-platform-access-cli/$version"

    docker build --build-arg QITS_CLI_VERSION="$version" -t qits/workspace-base:latest .

**The `--build-arg` is not optional.** `ARG QITS_CLI_VERSION` carries no default — the pom is the one
source of truth — and the build refuses an empty one rather than writing `qits=` into
`/etc/qits-cli-version`. That is the same expression the recipes use; the pom is read with `sed`
rather than with maven because the step image has no JDK in it.

That download URL answered 200 without a token when it was last measured (2026-09-14) and its
neighbour — the daemon list API — answered 401, so send the bearer and do not build a habit on the
open door. Inside a step container the recipes send the run's own `$QITS_TOKEN`; from your own
machine, `qits login` with an already-installed CLI is the easier road. The fetched file is
gitignored, so it never lands in a commit.

Expect a long, network-heavy build — roughly 3.4 GB of image, fetching two apt trees, a JDK, node,
a Chromium and several CLIs. CI allows two hours for it.

## Provenance — why this repository exists

Before this repository, the recipe lived only at
`~/code/qits-backend-devel/docker/qits/Dockerfile` as the `workspace` stage of the pre-split
monolith. That was the sole copy, it sat outside every repository, and it existed only on one
developer's disk. No CI could build a workspace image, and three Dockerfile headers elsewhere
pointed at it by a name it did not have.

The `Dockerfile` here is that stage copied verbatim, comments and pinned versions included. The one
change is dropping ` AS workspace` from the `FROM`, since the stage is now the whole image. It
therefore produces the same image the platform runs today.

Since qits-2657 the stage is named again, `workspace-base`, only so the `check` target can build on
it. A build that names no target still gets that stage unchanged.
