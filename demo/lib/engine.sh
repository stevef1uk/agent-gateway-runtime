#!/usr/bin/env bash
# ============================================================================
# engine.sh — Docker or Podman, the user's choice.
#
# Source this from any demo script, then use the wrappers instead of calling
# docker directly:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/engine.sh"
#   compose up -d          # → docker compose / podman compose / docker-compose
#   eng exec …  eng logs …  eng run …  eng rm …   # → docker|podman <verb>
#
# Selection order:
#   1. $CONTAINER_ENGINE env override (docker|podman)
#   2. $ENGINE env override (Makefile convention) — accepted as a fallback
#   3. docker, if its daemon is actually reachable
#   4. podman, if installed
#
# Podman notes (rootless):
#   * `podman compose` delegates to a provider (docker-compose or
#     podman-compose). The provider talks to the rootless Podman socket, so it
#     must be up:  systemctl --user start podman.socket
#     (or:  podman system service --time=0 &   if the unit is not installed)
#   * On Fedora/RHEL with SELinux enforcing, bind-mounted demo dirs may need
#     a relabel — use  :z  in an override file if mounts appear empty.
# ============================================================================

engine_detect() {
  # CONTAINER_ENGINE is the documented override; ENGINE is accepted as a
  # fallback so the Makefile's ENGINE=podman/docker convention (and the docs
  # that claim `ENGINE=podman make openclaw-demo` works) is honoured by the
  # script-driven targets too. Precedence: CONTAINER_ENGINE > ENGINE > probe.
  local e="${CONTAINER_ENGINE:-${ENGINE:-}}"
  if [ -n "$e" ]; then
    case "$e" in
      docker|podman) printf '%s\n' "$e"; return 0 ;;
      *) echo "engine.sh: CONTAINER_ENGINE must be 'docker' or 'podman' (got '$e')" >&2; return 1 ;;
    esac
  fi
  # Prefer a REACHABLE engine: a docker binary with a stopped daemon is useless.
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf 'docker\n'
  elif command -v podman >/dev/null 2>&1; then
    if command -v docker >/dev/null 2>&1; then
      echo "engine.sh: docker daemon unreachable — falling back to podman" >&2
    fi
    printf 'podman\n'
  else
    echo "engine.sh: neither docker nor podman usable (binary absent or daemon down)" >&2
    return 1
  fi
}

# Emit a hint when the Podman compose path cannot reach its API socket.
engine_podman_socket_hint() {
  local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
  if [ ! -S "$sock" ]; then
    echo "engine.sh: Podman API socket not found at $sock — start it with:" >&2
    echo "  systemctl --user start podman.socket   (or: podman system service --time=0 &)" >&2
    return 1
  fi
}

ENGINE="$(engine_detect)" || return 1 2>/dev/null || exit 1

# compose <args…> — the compose invocation for the chosen engine.
compose() {
  case "$ENGINE" in
    docker)
      if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
      elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
      else
        echo "engine.sh: no compose provider — install the docker compose plugin or docker-compose" >&2
        return 1
      fi
      ;;
    podman)
      if command -v podman-compose >/dev/null 2>&1 || [ -x "$HOME/.local/bin/podman-compose" ]; then
        # Daemonless provider: talks to podman directly, no API socket needed.
        export PODMAN_COMPOSE_PROVIDER="${PODMAN_COMPOSE_PROVIDER:-$(command -v podman-compose || printf '%s' "$HOME/.local/bin/podman-compose")}"
        podman compose "$@"
      else
        # docker-compose provider: needs the rootless Podman API socket.
        if ! engine_podman_socket_hint; then
          return 1
        fi
        export PODMAN_COMPOSE_PROVIDER="${PODMAN_COMPOSE_PROVIDER:-$(command -v docker-compose)}"
        export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
        podman compose "$@"
      fi
      ;;
  esac
}

# eng <verb> <args…> — generic passthrough (exec, logs, run, rm, pull, …).
eng() { "$ENGINE" "$@"; }
