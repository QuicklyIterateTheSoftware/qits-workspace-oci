# qits-workspace-oci

The workspace toolchain base image, published as **`qits/workspace-base`**.

It holds the tools a workspace container needs to work on a checkout: git and a shell toolchain,
JDK 25, node + pnpm, python, a pinned Playwright Chromium with a pinned font stack, the coding agent
CLIs (Claude Code, Kimi Code), language servers (jdtls, typescript-language-server), and the docker
**client**. Every package is commented in the `Dockerfile` with the reason it is there. Read that
before changing anything.

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

Three small things on PATH, all inert until qits-workspaces injects the environment they read:

- `qits-git-credential` — git's credential helper, answering the injected githost authority with a
  short-lived bearer minted from the container's commissioned client (and nothing else: a checkout
  can name arbitrary submodule remotes).
- `qits-token <audience>` — the same mint, for the hands that are not git: qits-projects' release
  requests, the ci run list, any platform API. One token per service, the audience is that service's
  alias.
- `qits-npm-ci [args]` — `npm ci` with the lockfile's developer-host `resolved` origins swapped for
  the platform's registries for the duration of the install and restored byte for byte afterwards.
  `npm` itself is a shim that carries the `@qits` scope (see the Dockerfile).

Plus `/etc/profile.d/qits-workspace.sh` for every login shell: a passwd entry for the arbitrary uid
and the Maven settings that reach the platform's plain-http repository.

## Building by hand

    docker build -t qits/workspace-base:latest .

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
