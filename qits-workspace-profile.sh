# Sourced by every login shell (/etc/profile.d). The workspace daemon runs EVERY command it starts
# as `bash -lc` — builds, actions, service supervision and both coding-agent harnesses — so this
# runs ahead of any build without this image owning an entrypoint and without a change to the
# daemon that is PID 1.
#
# Both fixes are idempotent and both fail soft: a login shell is never worth breaking over them.

# --- 1. give the container's arbitrary uid a name -------------------------------------------------
# The container runs as the deployment host's uid (qits-workspaces passes `--user <uid>`, group 0)
# and this image cannot know that number at build time, so the uid resolves to no user at all.
# Almost every tool is content with that. PostgreSQL is not: `initdb` calls getpwuid() and refuses
# to run when it cannot name its own user —
#
#     initdb: could not look up effective user ID 1000: user does not exist
#
# — so EVERY test that starts an embedded PostgreSQL fails inside a workspace and passes everywhere
# else: a developer machine has a passwd entry, and CI builds in a different image. That makes the
# gap invisible until someone runs a suite here. qits-deployments, qits-githost and
# qits-platform-edge all carry such suites today.
#
# /etc/passwd is group-writable for group 0 (see the Dockerfile, which explains the trade-off);
# the `-w` test is what keeps this silent rather than noisy where it is not.
if ! getent passwd "$(id -u)" >/dev/null 2>&1 && [ -w /etc/passwd ]; then
  printf 'qits:x:%s:%s:qits workspace:%s:/bin/bash\n' \
    "$(id -u)" "$(id -g)" "${HOME:-/workspace}" >> /etc/passwd
fi

# --- 2. point Maven at the platform's repositories ------------------------------------------------
# Every qits pom declares its platform repository as `qits-maven`, with a developer-host default
# address that does not exist inside a container; /etc/qits/maven-settings.xml mirrors that id to
# qits-artifacts' hosted maven, routes Maven Central through qits-mirror's cache, and sends the
# container's commissioned client pair to both as HTTP Basic. MAVEN_ARGS (Maven 3.9+) applies it to
# `./mvnw` as well as `mvn`, which matters because every repository here builds through its wrapper.
#
# THE ADDRESSES ARE CODE, NOT CONFIGURATION (qits-731). The platform's only input is QITS_DOMAIN;
# the hosts and paths are constants, derived here because Maven settings cannot compute a string —
# the file can only read ${env.*}, so this exports what it reads. Whatever qits-workspaces may still
# inject under these two names is overwritten, so the image works the same whether or not the
# service has stopped injecting them. Without QITS_DOMAIN the domain is wohlben.eu, as for the qits
# CLI; never an internal address. The public names answer from inside the platform network too.
qits_domain=${QITS_DOMAIN:-wohlben.eu}
QITS_MAVEN_REPOSITORY_URL="https://registry.qits.$qits_domain/artifacts/maven/maven"
QITS_MAVEN_CENTRAL_URL="https://mirror.qits.$qits_domain/mirror/maven/central"
export QITS_MAVEN_REPOSITORY_URL QITS_MAVEN_CENTRAL_URL
unset qits_domain

# INERT WITHOUT THE CREDENTIAL. Both hosts answer 401 anonymously, so routing Maven at them with no
# commissioned pair to send would fail every build that stock Maven Central would have served; the
# settings are applied only when the pair is there to authenticate with.
if [ -n "${QITS_COMMISSIONED_CLIENT_ID:-}" ] && [ -n "${QITS_COMMISSIONED_CLIENT_SECRET:-}" ]; then
  case " ${MAVEN_ARGS:-} " in
    # A caller that named its own settings keeps them — a repository's own
    # .qits-maven-settings.xml must still win when someone passes it.
    *" -s "* | *" --settings "*) : ;;
    *) MAVEN_ARGS="${MAVEN_ARGS:+$MAVEN_ARGS }-s /etc/qits/maven-settings.xml"; export MAVEN_ARGS ;;
  esac
fi
