#!/bin/sh
# preflight.sh - report the host facts this schematic's Parameters table needs.
#
# Read-only: it starts nothing, writes nothing, and prints no secret.
#
# Usage:  sh preflight.sh [project-directory]
# Env:    UPLOAD_LOCATION, DB_DATA_LOCATION, HTTP_PORT (optional; defaults below
#         are the schematic's own example defaults, not this host's values)

set -u

COMPOSE_DIR=${1:-${COMPOSE_DIR:-.}}
UPLOAD_LOCATION=${UPLOAD_LOCATION:-/srv/immich/library}
DB_DATA_LOCATION=${DB_DATA_LOCATION:-/srv/immich/postgres}
HTTP_PORT=${HTTP_PORT:-2283}

say() { printf '%s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "== Container runtime"
if have docker; then
    engine=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unavailable")
    say "engine:        $engine"
    case "$engine" in
        2[5-9].*|2[5-9].[0-9]*|[3-9][0-9].*|[0-9][0-9][0-9].*) say "start_interval: supported" ;;
        unavailable) say "start_interval: unknown (engine did not answer; is the daemon running?)" ;;
        *) say "start_interval: NOT supported (engine < 25) - remove that key from the database healthcheck" ;;
    esac
else
    say "engine:        docker not found - install Docker Engine before Phase 1"
fi
if have docker && docker compose version >/dev/null 2>&1; then
    say "compose:       $(docker compose version --short 2>/dev/null || echo present)"
else
    say "compose:       docker compose plugin not found - the v2 plugin is required"
fi
say "architecture:  $(uname -m)   (images are published for x86-64 and arm64)"

say ""
say "== Host capacity"
say "cores:         $( (have nproc && nproc) || getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
if have free; then
    say "memory:        $(free -h | awk '/^Mem:/{print $2" total, "$7" available"}')"
else
    say "memory:        free not available"
fi
say "swap:          $(awk '/^SwapTotal:/{print $2/1024 " MiB"}' /proc/meminfo 2>/dev/null || echo unknown)"

say ""
say "== Storage paths"
for path in "$UPLOAD_LOCATION" "$DB_DATA_LOCATION"; do
    if [ -d "$path" ]; then
        fs=$(findmnt -no FSTYPE -T "$path" 2>/dev/null || echo "?")
        avail=$(df -h "$path" 2>/dev/null | awk 'NR==2{print $4" free of "$2}')
        say "$path: fstype=$fs  $avail"
        case "$fs" in
            nfs*|cifs|smb*|fuse*|9p) say "  WARNING: $path looks like a network filesystem; the database rejects one" ;;
        esac
        say "  owner: $(stat -c '%u:%g' "$path" 2>/dev/null || echo unknown)"
    else
        say "$path: does not exist yet (create it in Phase 1)"
    fi
done

say ""
say "== Inference devices"
if [ -d /dev/dri ]; then say "dri:      $(ls /dev/dri | tr '\n' ' ')"; else say "dri:      none"; fi
if [ -e /dev/mali0 ]; then say "mali:     present (ARM NN possible)"; else say "mali:     absent"; fi
if [ -e /dev/kfd ]; then say "kfd:      present (ROCm possible)"; else say "kfd:      absent"; fi
if have nvidia-smi; then
    say "nvidia:   $(nvidia-smi -L 2>/dev/null | head -1 || echo 'tool present, no device answered')"
else
    say "nvidia:   no nvidia-smi (CUDA unavailable without the driver and container toolkit)"
fi
if [ -r /sys/kernel/debug/rknpu/version ]; then
    say "rknpu:    $(cat /sys/kernel/debug/rknpu/version 2>/dev/null)"
else
    say "rknpu:    not readable (RKNN needs a supported Rockchip SoC)"
fi

say ""
say "== Kernel limits"
if [ -r /proc/sys/fs/inotify/max_user_watches ]; then
    say "inotify watches: $(cat /proc/sys/fs/inotify/max_user_watches)  (library watching raises this need)"
else
    say "inotify watches: unreadable"
fi
say "timezone:        $( (have timedatectl && timedatectl show -p Timezone --value) || cat /etc/timezone 2>/dev/null || echo unknown)"

say ""
say "== Ports"
if have ss; then
    if ss -tln 2>/dev/null | grep -q "[:.]${HTTP_PORT}[[:space:]]"; then
        say "tcp/${HTTP_PORT}: already listening on this host - choose another HTTP_PORT or reuse that listener deliberately"
    else
        say "tcp/${HTTP_PORT}: free"
    fi
else
    say "tcp/${HTTP_PORT}: cannot check (ss not available)"
fi

say ""
say "== Resolve the four digests (run these, then record the sha256 values)"
say "  docker buildx imagetools inspect ghcr.io/immich-app/immich-server:<version>"
say "  docker buildx imagetools inspect ghcr.io/immich-app/immich-machine-learning:<version>[-backend]"
say "  docker buildx imagetools inspect ghcr.io/immich-app/postgres:<the tag the release names>"
say "  docker buildx imagetools inspect docker.io/valkey/valkey:<the major version the release names>"
say "Then copy host parameters into the record: templates/host-parameters.md"
say ""
say "Project directory to be used in Phase 1: $COMPOSE_DIR"
if [ -f "$COMPOSE_DIR/.env" ]; then
    say "  .env already exists there - read it before overwriting anything"
fi
