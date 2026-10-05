# The qits workspace toolchain base image, published as `qits/workspace-base`.
#
# It carries what a workspace container needs to work on a checkout: git and a shell toolchain,
# JDK 25, node + pnpm, python, a pinned Playwright Chromium with a pinned font stack, the coding
# agent CLIs (Claude Code, Kimi Code), a browser MCP server the agent drives (`qits-browser-mcp`),
# and language servers (jdtls, typescript-language-server).
#
# It carries NO daemon binary and no entrypoint. It is a base, not a runnable workspace.
# `qits-workspace-daemon`'s `docker/Dockerfile.workspace` layers the daemon on top of this image and
# entrypoints to it; that result is the image a workspace container runs.
#
# Provenance: extracted verbatim from the pre-split monolith's `workspace` stage in
# `docker/qits/Dockerfile`. That checkout was the only copy of this recipe and lived outside every
# repository, so no CI could build a workspace image. This repository is that home. The body below
# is unchanged apart from dropping ` AS workspace` from the `FROM` — the stage is the whole image
# now. Keep it that way: every pinned version here is a deliberate pin, and the comments explain
# why each package is installed.

# ---- the base: node and the screenshot renderer ---------------------------------------------
# `qits/build-images/node-browser-base` (qits-build-images-oci) is Debian bookworm with Node 24,
# Playwright's Chromium at a pinned version and a pinned font stack, recorded in
# /etc/qits-renderer-provenance. The `app` archetype's CI QA step runs `npm run test:browser` on the
# SAME image, so screenshot baselines an agent regenerates here match CI byte for byte. That is why
# the renderer is not installed in this file: one definition, two consumers.
#
# ONE LINE, ONE VERSION TOKEN, AND A MACHINE EDITS IT: qits-maintenance reads literal
# `ARG <NAME>=<image>:<tag>` defaults as docker pins and bumps the tag. Keep the value literal. The
# registry host is the builder's to resolve (its registry config maps the edge spelling in-network).
ARG BROWSER_BASE=registry.dev.localhost:8080/qits/build-images/node-browser-base:2026.1003.45515
FROM ${BROWSER_BASE}

ENV DEBIAN_FRONTEND=noninteractive

# git + a shell toolchain (setsid/kill come from util-linux/procps, needed for the registry's
# process-group termination), python, jq (JSON wrangling in scripts — e.g. the Claude Code
# statusline script on the shared /claude-home volume), and unzip. `inotify-tools` provides
# `inotifywait`, spawned per workspace by WorkspaceWatchService to push live working-tree changes
# (agent scaffolds a module/pom/test without a commit) out over the /events SSE channel so the file
# browser and detection refresh without a reload. `openssh-client` gives git an
# ssh transport for pushing/fetching ssh remotes — qits' own git verbs speak smart-HTTP to the
# in-process git server, but the devcontainer (which extends this image) pushes qits itself to an
# ssh origin, and VS Code only forwards the host ssh-agent into a container that has the client
# installed. `unzip` is required by the Maven wrapper: with
# `distributionType=only-script` the mvnw script silently falls back from the `.zip` distribution to
# `.tar.gz` when unzip is absent, which then fails `distributionSha256Sum` validation (the pinned sum
# is the zip's) — see the retired monolith's docs/issues/2026-07-05_workspace-image-cannot-build-fixture.md.
# `skopeo` is a real OCI client, needed by qits-artifacts' `qits` (OCI) userflow stories: they drive a
# `skopeo copy` push and pull against the registry the suite launches, and skip themselves when the
# binary is absent — so a workspace agent running that suite locally would see three stories quietly
# self-disable rather than fail.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        bash \
        gpg \
        jq \
        inotify-tools \
        openssh-client \
        unzip \
        util-linux \
        procps \
        python3 \
        python3-venv \
        tmux \
        ripgrep \
        fd-find \
        skopeo \
    && rm -rf /var/lib/apt/lists/*

# Git invokes a credential helper for every HTTP remote it needs credentials for.  This one mints a
# short-lived bearer from the per-workspace commissioned client, but answers ONLY the injected
# qits-githost authority.  A checkout can contain arbitrary submodule remotes, so a generic helper
# which answered those too would disclose a platform credential to repository-controlled hosts.
# The container factory enables it only when it injects the complete commissioned pair.
COPY qits-git-credential /usr/local/bin/qits-git-credential
RUN chmod 0755 /usr/local/bin/qits-git-credential \
    && sh -n /usr/local/bin/qits-git-credential \
    # A RUNNER workspace container carries QITS_TOKEN, its own opaque token minted and injected by
    # qits-workspaces, in preference to a commissioned pair to mint with — assert that branch
    # answers straight from it rather than discovering a regression the first time a workspace
    # clones over https.
    && out=$(printf 'protocol=https\nhost=h\n\n' \
         | QITS_TOKEN=t QITS_GIT_AUTH_HOST=h /usr/local/bin/qits-git-credential get) \
    && case "$out" in \
         *"password=t"*) ;; \
         *) echo "qits-git-credential: QITS_TOKEN branch did not answer password=t" >&2; exit 1 ;; \
       esac
RUN printf '[credential]\n\thelper = /usr/local/bin/qits-git-credential\n' > /etc/qits-gitconfig
# The same credential, for the hands that are not git: `qits-token <audience>` mints a bearer for one
# platform service (the release door, qits-ci's run list, …). Inert without the injected
# environment; it carries its reasoning in its header. It exists because an agent that could push,
# build and test inside a workspace still could not release from it without reverse-engineering the
# door (integrator.md, ad-hoc workspace 351, 2026-08-20).
#
# THESE TWO EXIST BECAUSE THERE WAS NO CLI, AND THERE IS ONE NOW: `qits`, at the foot of this file.
# It is what an agent should reach for first, and the block down there says why it sits last rather
# than here beside its ancestors. NEITHER IS RETIRED BY IT, which is worth stating so nobody reads
# the new block as a replacement: `qits-git-credential` is the helper /etc/qits-gitconfig names, so
# git itself runs it on every HTTP remote and no agent decision is involved; `qits-token` is named by
# the workspace guide and by action scripts written against it.
#
# There was a third, `qits-npm-ci`, which rewrote a lockfile's `resolved` origins for the duration of
# an install. It is gone (qits-731): the registries are public names that resolve everywhere, so a
# lockfile already names an address a workspace can reach, and nothing rewrites one.
COPY qits-token /usr/local/bin/qits-token
RUN chmod 0755 /usr/local/bin/qits-token \
    && sh -n /usr/local/bin/qits-token \
    # QITS_TOKEN wins over the pair and the audience argument is ignored outright — assert it
    # straight away rather than finding out via a 403 from the wrong audience.
    && out=$(QITS_TOKEN=t /usr/local/bin/qits-token x) \
    && [ "$out" = t ]
# `ripgrep`/`fd-find` are general CLI tools (they benefit action scripts) and are also where kimi's
# search tools resolve `rg`/`fd` on PATH — the pinned kimi installer below ships only the `kimi`
# binary, not the sidekicks a desktop install carries. Debian names fd `fdfind`, which kimi handles.

# JDK 25 (Temurin, via the Adoptium apt repo). The projects this image builds — the Quarkus+Angular
# fixture and qits itself — target `maven.compiler.release=25`, so JDK 17 (bookworm's default openjdk)
# cannot compile them.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" \
        > /etc/apt/sources.list.d/adoptium.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends temurin-25-jdk \
    && rm -rf /var/lib/apt/lists/* \
    # The Temurin deb installs to an arch-suffixed path (temurin-25-jdk-amd64 / -arm64) and puts
    # java/javac on PATH via alternatives, but sets no JAVA_HOME. Tools that discover the JDK by
    # JAVA_HOME rather than PATH — the VS Code Java extension / jdtls, and the jdtls-lsp Claude
    # plugin — then report "no Java runtime" despite java being installed. Pin a stable, arch-agnostic
    # symlink and export JAVA_HOME so every consumer (workspace containers + the devcontainer that
    # extends this image) finds it.
    && ln -s /usr/lib/jvm/temurin-25-jdk-* /usr/lib/jvm/temurin-25
ENV JAVA_HOME=/usr/lib/jvm/temurin-25

# Opt out of Quarkus build-time analytics non-interactively. Without a stored consent decision the
# Quarkus Maven plugin prompts "Do you agree to contribute anonymous build time data…" on every
# build — a blocker on a fresh, ephemeral container that has no ~/.redhat consent file yet. This env
# var (the config form of quarkus.analytics.disabled) disables it for every Quarkus build in the
# image: the devcontainer's reactor builds, the app-image build stage below, and each workspace
# container's fixture/agent builds.
ENV QUARKUS_ANALYTICS_DISABLED=true

# Same treatment for the Angular CLI: without a stored decision (~/.angular-config.json) it prompts
# "Would you like to share pseudonymous usage data…" on the first ng invocation. NG_CLI_ANALYTICS=false
# disables it non-interactively for every Angular build (Quinoa's frontend build + fixture builds).
ENV NG_CLI_ANALYTICS=false

# Node.js comes from the base (NodeSource, Node 24, corepack enabled); pnpm through corepack.
RUN corepack prepare pnpm@latest --activate

# ---- The docker CLI, for admin workspaces ---------------------------------------------------
# THE CLIENT ONLY, AND IT REACHES NOTHING BY ITSELF. `docker-ce-cli` is the `docker` command and
# nothing else: no daemon, no containerd, no socket. A workspace container has no docker socket
# unless it was created in ADMIN MODE (qits-workspaces' Workspace.admin — a per-workspace posture
# somebody asked for at creation, which qits-containers renders as the one bind plus the socket's
# own group), and in every other workspace this binary is inert: `docker ps` there answers "Cannot
# connect to the Docker daemon at unix:///var/run/docker.sock", which is the honest state.
#
# It is in the BASE rather than in a second image, because a second image is a second thing to
# build, tag, pin and keep matched — and the whole difference between the two would be 40 MB of CLI
# that does nothing without a bind only the platform can grant. The privilege is the socket; a
# client with no socket is a client with nothing to talk to.
#
# Docker's own apt repository, keyring-verified, arch-resolved by apt — the same shape as the
# Adoptium and NodeSource repositories above, and the reason this is not a static tarball pinned per
# architecture. The version floats with the repository like node's does: a CLI speaks to a daemon
# older and newer than itself by design (API version negotiation), so a pin here would buy nothing
# and would go stale against whatever docker the host runs.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/* \
    # The client, and only the client: a daemon in this image would be a second docker on the host's
    # network with none of the platform's rules, so assert what the layer installed rather than
    # trusting the package name to keep meaning what it means today.
    && [ -x /usr/bin/docker ] \
    && ! command -v dockerd

# ---- Screenshot-test renderer ----------------------------------------------------------------
# Inherited from the base (see the top of this file): Playwright's Chromium under
# PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright, the pinned fonts, and /etc/qits-renderer-provenance.
# Check here that the base still carries them, so a base without a renderer fails this build.
RUN test -n "${PLAYWRIGHT_BROWSERS_PATH}" \
    && grep -q '^chromium=' /etc/qits-renderer-provenance \
    && cat /etc/qits-renderer-provenance

# ---- A browser the coding agent can drive ----------------------------------------------------
# Microsoft's Playwright MCP server, so a coding agent can open what it serves (`ng serve`, a
# Quarkus dev server), click through it, take screenshots and read the console and network.
# qits-workspace-daemon attaches `qits-browser-mcp` to every Claude launch as the stdio MCP server
# `browser`; that script holds the flags and points the server at the base's Chromium, so this layer
# adds no second browser.
#
# THE PLAYWRIGHT PIN STAYS ONE PIN: the base's, recorded as `playwright=` in
# /etc/qits-renderer-provenance. @playwright/mcp is built on a Playwright alpha of its own, so its
# version cannot be that pin; PLAYWRIGHT_MCP_VERSION names the release built on the same
# major.minor, and the check below fails the build when the base moves to another one. When it
# does, pick the @playwright/mcp release whose `playwright` dependency has the new major.minor.
# npm-global for the same reason as the language servers below: it lands in /usr/bin for the
# arbitrary runtime uid.
ARG PLAYWRIGHT_MCP_VERSION=0.0.80
RUN npm install -g @playwright/mcp@${PLAYWRIGHT_MCP_VERSION} \
    && rm -rf /root/.npm \
    && base="$(sed -n 's/^playwright=\([0-9]*\.[0-9]*\).*/\1/p' /etc/qits-renderer-provenance)" \
    && mcp="$(node -p "require('$(npm root -g)/@playwright/mcp/node_modules/playwright-core/package.json').version" | cut -d. -f1,2)" \
    && { [ -n "$base" ] && [ "$base" = "$mcp" ] || { \
         echo "@playwright/mcp ${PLAYWRIGHT_MCP_VERSION} is built on Playwright $mcp, the base bakes $base: pick the release on $base" >&2; \
         exit 1; }; } \
    && playwright-mcp --help >/dev/null
COPY qits-browser-mcp /usr/local/bin/qits-browser-mcp
RUN chmod 0755 /usr/local/bin/qits-browser-mcp && sh -n /usr/local/bin/qits-browser-mcp

# The coding agent (Claude Code) runs inside this container — the single biggest executor of
# arbitrary commands in the sandbox. Bake the CLI in at a pinned version (bump CLAUDE_CODE_VERSION
# to any published release; the build fails loudly if it doesn't exist). The native installer
# (claude.ai/install.sh) downloads the standalone binary into ~/.local/bin; we relocate it to
# /usr/local/bin so it's on PATH for the arbitrary runtime uid the container runs as. Auto-updates
# are disabled (immutable image — bump the ARG to upgrade).
ARG CLAUDE_CODE_VERSION=2.1.283
RUN curl -fsSL https://claude.ai/install.sh | bash -s ${CLAUDE_CODE_VERSION} \
    && cp -L /root/.local/bin/claude /usr/local/bin/claude \
    && rm -rf /root/.local/bin/claude /root/.local/share/claude /root/.claude
ENV DISABLE_AUTOUPDATER=1

# Kimi Code CLI — the second coding-agent harness (the retired monolith's docs/epics/qits-coding-agents/feature-ideas/kimi-code-harness.md).
# Same treatment as Claude Code: pinned version (KIMI_VERSION fails the build loudly on an unknown
# version), installed system-wide via KIMI_INSTALL_DIR=/usr/local so the arbitrary runtime uid finds
# it on PATH — the pinned installer drops only the `kimi` binary itself into bin/ (the ~/.kimi-code/bin
# `rg`/`fd` sidekicks a desktop install carries are absent here; they come from the base apt layer
# above instead). No shell-rc edits (KIMI_NO_MODIFY_PATH — /usr/local/bin is already on PATH) and the
# update preflight is disabled (immutable image — bump the ARG to upgrade). The trailing `kimi
# --version` turns a download failure into a loud build break: `curl … | bash` without pipefail would
# otherwise swallow a curl error (bash reads empty stdin and exits 0), shipping an image with no kimi.
ARG KIMI_CODE_VERSION=0.28.1
RUN curl -fsSL https://code.kimi.com/kimi-code/install.sh \
        | KIMI_VERSION=${KIMI_CODE_VERSION} KIMI_INSTALL_DIR=/usr/local KIMI_NO_MODIFY_PATH=1 bash \
    && kimi --version
ENV KIMI_CODE_NO_AUTO_UPDATE=1

# Language servers for the coding agent's LSP plugins (jdtls-lsp / typescript-lsp from the
# claude-plugins-official marketplace — see the retired monolith's docs/epics/qits-coding-agents/features/2026-07-07_agent-lsp-plugins.md). The
# plugins only *wire up* a language server that must already be on PATH; they do not bundle one. The
# binaries are HOME-independent common toolchain (unlike the plugins themselves, which live on the
# shared /claude-home volume and are installed at runtime), so they belong in the image next to the
# JDK/Node they build on.
#
# typescript-lsp -> `typescript-language-server` (+ `typescript`) on PATH, installed npm-global so
# it lands in /usr/bin for the arbitrary runtime uid.
RUN npm install -g typescript-language-server typescript

# jdtls-lsp -> `jdtls` on PATH (Eclipse JDT language server; needs a JDK — temurin-25 above). The
# distribution ships a `bin/jdtls` python launcher; unpack it under /opt and symlink the launcher
# onto PATH. Pinned to a snapshot tarball via ARG so a build can bump/repin without editing the
# recipe; `bin/jdtls` presence is asserted so a structure change fails the build loudly rather than
# at agent runtime.
ARG JDTLS_URL=https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz
# `--no-same-owner`: every entry in Eclipse's tarball is owned by 1001380000:1001380000 (their
# OpenShift build host), which is outside a rootless/user-namespaced docker's id map — buildkitd on
# such a runner fails the extract with "failed to Lchown ... (Hint: try increasing the number of
# subordinate IDs in /etc/subuid and /etc/subgid)". There is no host-side fix for that; the image
# just must not produce files above the mappable range in the first place (qits-556).
RUN mkdir -p /opt/jdtls \
    && curl -fsSL "${JDTLS_URL}" -o /tmp/jdtls.tar.gz \
    && tar -xz --no-same-owner -C /opt/jdtls -f /tmp/jdtls.tar.gz \
    && rm -f /tmp/jdtls.tar.gz \
    && test -f /opt/jdtls/bin/jdtls \
    && ln -s /opt/jdtls/bin/jdtls /usr/local/bin/jdtls

# Mount point for the shared credential volume (qits.workspace.claude-volume, default
# qits_shared_dot_claude). Agent launches set HOME here so `claude` reads the operator's one-time
# OAuth login (~/.claude) off the volume — see docker/workspace/agent-login.sh. World-writable so
# the empty named volume initializes writable and the arbitrary-uid container can write to it.
RUN mkdir -p /claude-home && chmod 0777 /claude-home

# Mount points for the shared build caches (qits.workspace.maven-volume / pnpm-volume, default
# qits_shared_m2 / qits_shared_pnpm). qits mounts these into every workspace container AND its own
# devcontainer, and points Maven (-Dmaven.repo.local=/caches/m2 via MAVEN_OPTS) and pnpm
# (npm_config_store_dir=/caches/pnpm/store) at them — so a dependency downloaded by one build is
# reused by every other. World-writable for the same reason as /claude-home (empty named volume,
# arbitrary-uid container).
RUN mkdir -p /caches/m2 /caches/pnpm/store && chmod -R 0777 /caches

# Cloned repositories live here; DockerExecutor execs commands with -w /workspace. The container
# runs as an arbitrary host uid (--user $(id -u)) with no matching passwd entry, so make /workspace
# world-writable (the clone happens as that uid) and point HOME at it so git/tools have somewhere to
# write. Git only ever uses the repo-local config qits sets after cloning.
RUN mkdir -p /workspace && chmod 0777 /workspace
ENV HOME=/workspace
WORKDIR /workspace

# The container runs as an arbitrary uid that owns neither /workspace (created here as root) nor
# necessarily every cloned file, which trips git's "detected dubious ownership" guard and would fail
# every container-side git verb. The whole container is a single-tenant sandbox, so mark all
# directories safe (system-wide, at build time as root).
RUN git config --system --add safe.directory '*'

# --- what a build inside a workspace needs ---------------------------------------------------------
# Everything above equips the container to RUN a toolchain. These two lines are what let it BUILD
# the platform's own repositories, and both address the same root cause: this image is entered as an
# arbitrary uid on a network whose addresses it does not know, and Maven and PostgreSQL each refuse
# to work under exactly one of those conditions. Measured on the live platform, where
# `./mvnw verify` on a qits repository failed in three seconds on the first and, once past it, went
# on to fail every embedded-PostgreSQL test on the second.
#
# The reasoning for each is in the script and the settings file; they are commented at length
# because both failures name a symptom far from the cause.
#
# /etc/passwd IS GROUP-WRITABLE, WHICH IS A DELIBERATE TRADE. Group 0 is the group the container
# runs with, so the profile snippet can append its own entry; this is the arbitrary-uid convention
# Red Hat documents for OpenShift images (`chmod g=u /etc/passwd`) and it is the only mechanism that
# works for a uid chosen after the image is built, short of preloading an NSS shim into every
# process. What it costs: a container process can write a passwd entry, and `su` is setuid, so
# in-container root is reachable from inside. That is judged acceptable HERE and would not be
# elsewhere — this container is a single-tenant sandbox whose entire purpose is executing arbitrary
# agent code, it already runs with a world-writable /workspace and holds its own platform
# credential, and it mounts no docker socket, so in-container root grants no reach the session did
# not already have. If that judgement is ever revisited, libnss-wrapper is the alternative and the
# profile snippet is the only caller to change.
COPY qits-maven-settings.xml /etc/qits/maven-settings.xml
# The QITS_TOKEN form of the same settings — a bearer header instead of the commissioned pair as
# HTTP Basic, no username or password at all — which the profile snippet below picks in preference
# to the pair's whenever a workspace carries a token. See the file's own header for the full
# reasoning; it is otherwise byte-for-byte the pair settings.
COPY qits-maven-settings-token.xml /etc/qits/maven-settings-token.xml
COPY qits-workspace-profile.sh /etc/profile.d/qits-workspace.sh
RUN chmod 0644 /etc/qits/maven-settings.xml /etc/qits/maven-settings-token.xml /etc/profile.d/qits-workspace.sh \
    && chmod g=u /etc/passwd \
    # A login shell must survive this file, so a syntax error has to break the BUILD, not every
    # command in every workspace: bash -n parses without executing.
    && bash -n /etc/profile.d/qits-workspace.sh \
    # QITS_TOKEN must win over the pair: assert the profile names the token settings rather than
    # discovering at run time that a workspace token build is quietly sending the pair instead.
    && out=$(QITS_TOKEN=t bash -c '. /etc/profile.d/qits-workspace.sh; echo $MAVEN_ARGS') \
    && case "$out" in \
         *maven-settings-token.xml*) ;; \
         *) echo "qits-workspace-profile.sh: QITS_TOKEN did not select the token settings (MAVEN_ARGS=$out)" >&2; exit 1 ;; \
       esac \
    # Both settings files must be well-formed, and the token one must carry the httpHeaders block
    # on both <server> entries — xmllint where the image has it (it does not, by default), a grep
    # count otherwise.
    && if command -v xmllint >/dev/null 2>&1; then \
         xmllint --noout /etc/qits/maven-settings.xml /etc/qits/maven-settings-token.xml; \
       else \
         [ "$(grep -c '<httpHeaders>' /etc/qits/maven-settings-token.xml)" = 2 ]; \
       fi

# npm's registries, which the environment cannot fully carry. `npm_config_@qits:registry` is npm's
# only spelling for the scope and is neither a POSIX env name (qits-containers refuses it,
# deliberately) nor something a shell can export — so it is injected per-invocation by a shim ahead
# of the real npm on PATH. The shim's header carries the full reasoning, including why a .npmrc
# cannot do this job.
#
# It shadows `npm`, which is worth stating plainly: `command -v npm` reports /usr/local/bin/npm here.
# That is the cost of covering the invocations nobody types — Quinoa resolves `npm` from PATH and
# spawns it straight from the Maven JVM, so a shell function or alias would miss exactly the builds
# that matter most.
#
# Both registries are code plus QITS_DOMAIN (qits-731): the @qits scope at
# https://registry.qits.<domain>/artifacts/npm/npm/ and everything else through the npmjs cache at
# https://mirror.qits.<domain>/npm/npmjs/. Both hosts want the container's commissioned client pair
# as HTTP Basic, and npm's per-host `//<host>/:_auth` key is the same non-exportable kind of name as
# the scope's, so the shim carries that too.
COPY qits-npm-shim.sh /usr/local/bin/npm
RUN chmod 0755 /usr/local/bin/npm \
    && bash -n /usr/local/bin/npm \
    # The credential is base64-encoded in the shim; coreutils is essential on Debian, but a shim that
    # silently sends an empty `_auth` is a 401 far from its cause, so assert the tool is there.
    && command -v base64 >/dev/null \
    # The shim must sit AHEAD of the real npm, not behind it: if PATH ever puts /usr/bin first this
    # silently stops applying, and a workspace goes back to resolving @qits from the public
    # registry. Assert the resolution at build time rather than discovering it in a build log.
    && [ "$(command -v npm)" = /usr/local/bin/npm ] \
    && [ -x /usr/bin/npm ]

# ---- the qits CLI, on PATH in every agent container ------------------------------------------
# `qits` is the platform's own command line, and it is the thing an agent should reach for before
# either of the two shell helpers above: projects and repositories, tickets, epics, release requests,
# CI runs and their logs, domain events, live telemetry, and `qits artifacts publish` for a CI step.
# It needs no login here — inside a container it signs ITSELF in from the commissioned pair
# ($QITS_COMMISSIONED_CLIENT_ID / $QITS_COMMISSIONED_CLIENT_SECRET) that qits-workspaces injects, so
# there is nothing for a session to hand it and no token for an agent to hold. Every agent container
# — workspace, editor, project-agent — is built FROM this image, which is the whole reason the binary
# belongs in the base rather than in three consuming Dockerfiles that would each pin it separately.
#
# THE BINARY ARRIVES WITH THE BUILD CONTEXT; THIS FILE ONLY COPIES IT. That is the part worth
# reading twice, because the obvious recipe — a `curl` here, like the Claude Code, Kimi and jdtls
# layers above — cannot work. Those three dial the OPEN INTERNET, and buildkitd can reach it; this
# one would have to dial the PLATFORM, and .config/qits/release.yml says at length
# that this build dials nothing on the platform: it runs in buildkitd's namespace on qits-net, with
# no commissioned credential and no platform address anywhere in the recipe. Fixing that here means
# a build arg for the store's URL and a secret mount for the credential, and a deliberately hermetic
# build stops being one — a large change for one 42 MB file.
#
# That store is also gated, mostly. Measured 2026-09-14 against dev-qits-artifacts:8080:
# `GET /artifacts/api/repositories/daemons/daemons` answers 401 with no token, 200 with a
# `qits-platform` bearer, and 401 for HTTP basic with the commissioned pair; the single download URL
# the recipes use answered 200 anonymously on the same day, and they send the bearer regardless —
# the reasoning is beside the fetch, in both of them.
#
# The CI STEP container already holds both halves — CiDaemonLauncher injects
# QITS_COMMISSIONED_CLIENT_ID, QITS_COMMISSIONED_CLIENT_SECRET and QITS_GIT_AUTH_TOKEN_URL into
# every step, and the recipe derives the artifacts store's address itself from QITS_DOMAIN
# (qits-731; `wohlben.eu` where it is not injected) — so the STEP mints the bearer and fetches the
# file, and `buildctl build --local context=.` sends it up with everything else. Both recipes carry
# that fetch, byte for byte identical, exactly as their buildctl lines already are.
#
# THE VERSION IS NOT IN THIS FILE. It is a maven property pin — `qits.platform-access-cli-binary.version`
# in this repository's `pom.xml`, on a dependency of `eu.wohlben.qits:qits-platform-access-cli-binary`
# — and the `ARG` below has NO DEFAULT: both recipes read the property out of the pom, fetch that
# version from the daemons store, and pass it in with `--opt build-arg:QITS_CLI_VERSION=`. One source
# of truth, so the pin and the fetch cannot drift; a default here would be a second one, and two
# strings that must agree eventually do not.
#
# WHY IT MOVED OUT OF THIS FILE, since the `ARG` was the more obvious home and held it for months.
# Nothing bumped it and nothing kept it alive. qits-platform-maintenance DOES read this Dockerfile —
# its DockerParser walks ARG lines — but the ARG arm only records a value shaped like an image
# reference, and a bare version has no slash in it; DockerParserTest says it outright, "a plain
# version names no image". So the line was discarded before it was ever a pin, and no bump commit ever
# touched it. Meanwhile the daemons store collects at `window=P0D` behind RELEASES_KEPT=2 and files
# pins for maven, npm and docker only, so nothing held the pinned version back either: the second
# qits-platform-access-cli release after a pin evicted it. The pin rotted on a clock, twice in three
# days (10599c6, 2d2ddd6), each time as `curl: (22) ... 404` out of the recipe that prepares this
# build's context. A maven property pin is both halves at once and needed no new machinery anywhere:
# PomParser records it, the bump step's maven arm edits it on a maintenance/* branch, this
# repository's release request gates the move, and the GC keeps the binary because a released maven
# pin names it. pom.xml carries the argument in full. Ticket d0b1965f.
#
# PINNED INTO THE IMAGE, NOT DOWNLOADED AT CONTAINER START — the decision, and it matches ticket
# ead74408's direction for CI: a container runs the version its image was built with, and it starts
# with no download, no store to be reachable and no latest-version lookup to answer differently on
# two consecutive container creations. Moving the pin is one line in `pom.xml` and a release of this
# repository, with the consuming images taking the new base — and in normal work nobody moves it by
# hand at all, because the maintenance pipeline does.
#
# IT SITS AT THE FOOT OF THE FILE, NOT BESIDE ITS TWO ANCESTORS ABOVE, AND THAT IS DELIBERATE. A
# `COPY` is cache-keyed on the file's content, so every layer BELOW it rebuilds when the pin moves.
# Beside the helpers it would sit above the JDK, node, the docker client, the Playwright Chromium,
# Claude Code, Kimi and jdtls — so bumping the CLI would re-assemble ~3.4 GB of toolchain from the
# network, on a pipeline that budgets two hours precisely because it expects that work to be cache
# hits. Here, a bump costs one layer. The comment on the helper block above is the pointer that keeps
# the two readable as one subject.
#
# A HAND-RUN `docker build` MUST FETCH THE FILE INTO THIS DIRECTORY FIRST AND PASS THE ARG —
# README.md gives the exact curl, bearer and `--build-arg` line. Without the file the COPY fails
# outright, and without the arg the RUN below does; both are the right place to find out.
ARG QITS_CLI_VERSION
COPY qits /usr/local/bin/qits
RUN chmod 0755 /usr/local/bin/qits \
    # A download is the step that goes wrong QUIETLY: a truncated body, an error page the store
    # answered 200 with, a binary built for the other architecture. Run it once, here, so a bad fetch
    # breaks THIS BUILD rather than every agent container that ever starts from the image — `--help`
    # is the cheapest invocation that still has to load and start the whole picocli command surface.
    #
    # The version is NOT asserted out of the binary, and that is a finding rather than an oversight:
    # the CLI takes picocli's `mixinStandardHelpOptions` with no `versionProvider` (AccessCli.java,
    # read 2026-09-14), so `qits --version` prints NOTHING and exits 0 — measured on the pinned
    # binary the same day, zero bytes of output, and in this image's environment not even that (the
    # QUARKUS_ANALYTICS_DISABLED set above makes it emit one unrelated Quarkus warning instead). A
    # check against it would assert nothing at all, which is worse than no check because it reads
    # like one. The build arg is therefore the only statement of which version this image ships, and
    # recording it in a file is what makes it answerable from INSIDE a container: a LABEL needs a
    # docker daemon and a caller that knows its own container id, which is the same reasoning as
    # /etc/qits-renderer-provenance above.
    #
    # WHICH IS EXACTLY WHY AN UNPASSED ARG HAS TO BREAK THE BUILD. An `ARG` with no default expands
    # to the empty string — silently, like every other unset shell variable — so without this guard a
    # builder that forgot `--build-arg` would produce a perfectly working image whose one statement
    # about its own CLI reads `qits=`. That is worse than a missing file: the COPY above fails loudly
    # when the binary is absent, while an empty version is a wrong answer given confidently to
    # everything that reads /etc/qits-cli-version afterwards. The recipes read the version out of
    # pom.xml and pass it; a hand-run build passes it the same way (README.md).
    && { [ -n "${QITS_CLI_VERSION}" ] || { \
         echo "QITS_CLI_VERSION was not passed: build with --build-arg QITS_CLI_VERSION=<pom.xml's qits.platform-access-cli-binary.version>" >&2; \
         exit 1; }; } \
    && /usr/local/bin/qits --help >/dev/null \
    && echo "qits=${QITS_CLI_VERSION}" > /etc/qits-cli-version

# Guard of last resort, run last so it sees every layer above: fail the build if anything on the
# image landed owned by a uid or gid above 65535 — the jdtls extraction above is fixed with
# `--no-same-owner`, but a future upstream tarball (or anything added later in this file) could
# reintroduce the same shape. A CI runner whose docker lives in a user namespace cannot map such an
# id and fails to even mount the image (qits-556); catching it here fails THIS build's own gate
# instead of every consumer's, on whatever runner happens to build them. `-xdev` stays within this
# image's one filesystem (no bind mounts are active at build time, so there is nothing else to
# cross into) and so never descends into /proc or /sys, which are not part of the image anyway.
RUN bad="$(find / -xdev \( -uid +65535 -o -gid +65535 \) -print 2>/dev/null | head -20)"; \
    if [ -n "$bad" ]; then \
        echo "Files owned by an id above 65535 (a CI runner in a user namespace cannot map them - qits-556):" >&2; \
        echo "$bad" >&2; \
        exit 1; \
    fi
