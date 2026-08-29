# The qits workspace toolchain base image, published as `qits/workspace-base`.
#
# It carries what a workspace container needs to work on a checkout: git and a shell toolchain,
# JDK 25, node + pnpm, python, a pinned Playwright Chromium with a pinned font stack, the coding
# agent CLIs (Claude Code, Kimi Code), and language servers (jdtls, typescript-language-server).
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
FROM debian:bookworm-slim

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
RUN chmod 0755 /usr/local/bin/qits-git-credential
RUN printf '[credential]\n\thelper = /usr/local/bin/qits-git-credential\n' > /etc/qits-gitconfig
# The same credential, for the hands that are not git: `qits-token <audience>` mints a bearer for one
# platform service (the release door, qits-ci's run list, …), and `qits-npm-ci` is `npm ci` with the
# lockfile's developer-host origins swapped for the platform's registries and then restored byte for
# byte. Both are inert without the injected environment; both carry their reasoning in their headers.
# They exist because an agent that could push, build and test inside a workspace still could not
# release from it without reverse-engineering the door (integrator.md, ad-hoc workspace 351,
# 2026-08-20) — the guide now names these two.
COPY qits-token /usr/local/bin/qits-token
COPY qits-npm-ci /usr/local/bin/qits-npm-ci
RUN chmod 0755 /usr/local/bin/qits-token /usr/local/bin/qits-npm-ci \
    && sh -n /usr/local/bin/qits-token && sh -n /usr/local/bin/qits-npm-ci
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

# Node.js (via NodeSource) + pnpm through corepack.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && corepack enable \
    && corepack prepare pnpm@latest --activate \
    && rm -rf /var/lib/apt/lists/*

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

# ---- Screenshot-test renderer: pinned fonts + Playwright Chromium ---------------------------
# The visual baselines committed under the consuming SPA's source tree (__screenshots__/*.png) are only
# reproducible on the exact Chromium build AND font stack that rendered them, so both are baked
# into this image, which is the sole sanctioned producer of baselines — see
# the retired monolith's docs/epics/qits-build-setup/features/2026-07-13_screenshot-baseline-renderer-baked-into-image.md and the
# screenshot-tests skill. Fonts first, in their own layer (they essentially never change; the
# browser layer below changes on playwright bumps): fontconfig + DejaVu (Chromium's default Linux
# sans-serif fallback), Liberation (metric-compatible Arial/Helvetica/Times), Noto core + color
# emoji (broad Unicode/emoji fallback, so a stray glyph rasterizes identically everywhere instead
# of from a host font).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        fontconfig \
        fonts-dejavu-core \
        fonts-liberation \
        fonts-noto-core \
        fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# The Playwright-managed Chromium, keyed to the playwright version the frontend lockfile resolves —
# PLAYWRIGHT_VERSION MUST match the consuming SPA's lockfile (grep "playwright@" there).
# Bump both together, rebuild this image, and re-record the baselines: that pairing is the
# intended, reviewable re-record event. A lockfile bump without an image rebuild fails loudly at
# test time with "Executable doesn't exist at /opt/ms-playwright/…" — that error means "rebuild
# this image", never "playwright install locally". Installed to a FIXED path via
# PLAYWRIGHT_BROWSERS_PATH rather than the default ~/.cache/ms-playwright, because workspace
# containers run as an arbitrary uid with HOME=/workspace and the devcontainer as `dev` with
# HOME=/home/dev — a per-HOME cache would be invisible to both. npx (not pnpm) because no
# package.json exists at image build time; --with-deps apt-installs Chromium's shared-library and
# supplemental font dependencies (it shells apt-get install, so the apt lists must be refreshed
# first in the same layer).
ARG PLAYWRIGHT_VERSION=1.61.0
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN apt-get update \
    && npx -y playwright@${PLAYWRIGHT_VERSION} install --with-deps chromium \
    && chmod -R a+rX ${PLAYWRIGHT_BROWSERS_PATH} \
    && rm -rf /root/.npm /var/lib/apt/lists/*

# Renderer provenance, greppable from inside any container (a LABEL is readable only through a
# docker daemon, by a caller that knows its own container id — the CLI above is inert in every
# workspace but an admin one — so a file beats a LABEL): the exact Chromium build plus every baked
# font package — including
# the supplemental fonts --with-deps pulled in, hence the 'fonts-*' glob rather than the five named
# above (grep -v drops known-but-not-installed packages the glob also matches). The trailing grep
# asserts the chromium line made it in, so a browser-layout change (the chrome-linux64 path is
# playwright-version-specific) fails the build loudly instead of leaving provenance silently
# incomplete. The screenshot-tests skill's baseline-provenance note points here.
RUN { echo "playwright=${PLAYWRIGHT_VERSION}"; \
      ${PLAYWRIGHT_BROWSERS_PATH}/chromium-*/chrome-linux*/chrome --version | sed 's/^/chromium=/'; \
      dpkg-query -W -f='${Package}=${Version}\n' fontconfig 'fonts-*' | grep -v '=$'; \
    } > /etc/qits-renderer-provenance \
    && grep -q '^chromium=' /etc/qits-renderer-provenance \
    && cat /etc/qits-renderer-provenance

# The coding agent (Claude Code) runs inside this container — the single biggest executor of
# arbitrary commands in the sandbox. Bake the CLI in at a pinned version (bump CLAUDE_CODE_VERSION
# to any published release; the build fails loudly if it doesn't exist). The native installer
# (claude.ai/install.sh) downloads the standalone binary into ~/.local/bin; we relocate it to
# /usr/local/bin so it's on PATH for the arbitrary runtime uid the container runs as. Auto-updates
# are disabled (immutable image — bump the ARG to upgrade).
ARG CLAUDE_CODE_VERSION=2.1.226
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
RUN mkdir -p /opt/jdtls \
    && curl -fsSL "${JDTLS_URL}" -o /tmp/jdtls.tar.gz \
    && tar -xz -C /opt/jdtls -f /tmp/jdtls.tar.gz \
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
COPY qits-workspace-profile.sh /etc/profile.d/qits-workspace.sh
RUN chmod 0644 /etc/qits/maven-settings.xml /etc/profile.d/qits-workspace.sh \
    && chmod g=u /etc/passwd \
    # A login shell must survive this file, so a syntax error has to break the BUILD, not every
    # command in every workspace: bash -n parses without executing.
    && bash -n /etc/profile.d/qits-workspace.sh

# The @qits scope, which the environment cannot carry. `npm_config_@qits:registry` is npm's only
# spelling for it and is neither a POSIX env name (qits-containers refuses it, deliberately) nor
# something a shell can export — so it is injected per-invocation by a shim ahead of the real npm on
# PATH. The shim's header carries the full reasoning, including why a .npmrc cannot do this job.
#
# It shadows `npm`, which is worth stating plainly: `command -v npm` reports /usr/local/bin/npm here.
# That is the cost of covering the invocations nobody types — Quinoa resolves `npm` from PATH and
# spawns it straight from the Maven JVM, so a shell function or alias would miss exactly the builds
# that matter most. The shim execs the real binary and adds nothing when the platform has told us no
# registry.
COPY qits-npm-shim.sh /usr/local/bin/npm
RUN chmod 0755 /usr/local/bin/npm \
    && bash -n /usr/local/bin/npm \
    # The shim must sit AHEAD of the real npm, not behind it: if PATH ever puts /usr/bin first this
    # silently stops applying, and a workspace goes back to resolving @qits from the public
    # registry. Assert the resolution at build time rather than discovering it in a build log.
    && [ "$(command -v npm)" = /usr/local/bin/npm ] \
    && [ -x /usr/bin/npm ]
