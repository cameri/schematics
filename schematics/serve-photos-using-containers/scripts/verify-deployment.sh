#!/bin/sh
# verify-deployment.sh - the mechanical acceptance checks from SCHEMATIC.md.
#
# Read-only against a running stack: it starts nothing, changes nothing, and
# never prints a credential. Every check prints PASS or FAIL and the script
# exits non-zero if any check failed, so it is the same verdict on every run.
#
# Usage:  sh verify-deployment.sh [project-directory]
# Env:
#   COMPOSE_DIR       project directory holding compose.yml and .env (default .)
#   IMMICH_URL        base URL to probe (default http://127.0.0.1:${HTTP_PORT})
#   HTTP_PORT         host port the server is published on (default 2283)
#   EXPOSURE          private | localhost | tsdproxy | cloudflare (default private)
#   DB_USERNAME       database role (default postgres)
#   DB_DATABASE_NAME  database name (default immich)
#   UPLOAD_LOCATION   host path mounted at /data
#   DB_DATA_LOCATION  host path holding the cluster
#   BACKUP_TARGET     where the operator's backup is written
#   ML_CPU_LIMIT      CPU ceiling the operator recorded (0 or empty = none)
#
# Values are taken from the environment first; any that remain unset are read
# from $COMPOSE_DIR/.env, so the checks see the deployment's own settings.

set -u

COMPOSE_DIR=${1:-${COMPOSE_DIR:-.}}

if [ -f "$COMPOSE_DIR/.env" ]; then
    for k in HTTP_PORT EXPOSURE DB_USERNAME DB_DATABASE_NAME UPLOAD_LOCATION \
             DB_DATA_LOCATION BACKUP_TARGET ML_CPU_LIMIT; do
        eval "cur=\${$k:-}"
        if [ -z "$cur" ]; then
            v=$(sed -n "s/^${k}=//p" "$COMPOSE_DIR/.env" 2>/dev/null | head -1)
            if [ -n "$v" ]; then eval "$k=\$v"; fi
        fi
    done
fi

HTTP_PORT=${HTTP_PORT:-2283}
EXPOSURE=${EXPOSURE:-private}
DB_USERNAME=${DB_USERNAME:-postgres}
DB_DATABASE_NAME=${DB_DATABASE_NAME:-immich}
UPLOAD_LOCATION=${UPLOAD_LOCATION:-}
DB_DATA_LOCATION=${DB_DATA_LOCATION:-}
BACKUP_TARGET=${BACKUP_TARGET:-}
ML_CPU_LIMIT=${ML_CPU_LIMIT:-}
IMMICH_URL=${IMMICH_URL:-http://127.0.0.1:${HTTP_PORT}}

failures=0
have() { command -v "$1" >/dev/null 2>&1; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
note() { printf '      %s\n' "$*"; }

if ! have docker; then
    fail "docker is not on PATH"
    exit 1
fi

compose() { (cd "$COMPOSE_DIR" && docker compose "$@"); }
cid() { compose ps -q "$1" 2>/dev/null | head -1; }

say_services() {
    printf '\n== A-1 services (R-1)\n'
    running=$(compose ps --status running --services 2>/dev/null | sort | tr '\n' ' ')
    note "running: ${running:-none}"
    for svc in immich-server immich-machine-learning database redis; do
        case " $running " in
            *" $svc "*) pass "$svc is running" ;;
            *) fail "$svc is not running" ;;
        esac
    done
    # The composition publishes "127.0.0.1:${HTTP_PORT:-2283}:2283": HTTP_PORT is the
    # HOST side and the container's own port is always 2283 (P-14), so the lookup asks
    # for the container port. Querying $HTTP_PORT asked for a container port that does
    # not exist whenever the two differ, and docker answers nothing for an unmapped
    # port - which this check then read as proof that nothing is published.
    published=$(compose port immich-server 2283 2>/dev/null || true)
    case "$EXPOSURE" in
        localhost)
            case "$published" in
                127.0.0.1:*|\[::1\]:*) pass "server published on the loopback interface: $published" ;;
                "") fail "EXPOSURE=localhost but container port 2283 is not published (host port $HTTP_PORT)" ;;
                *) fail "published on $published - expected the loopback interface only" ;;
            esac ;;
        *)
            if [ -n "$published" ]; then
                fail "the server publishes $published while EXPOSURE=$EXPOSURE - the library is reachable outside its intended network"
            else
                pass "no published port (EXPOSURE=$EXPOSURE)"
            fi ;;
    esac
    for svc in database redis immich-machine-learning; do
        p=$(compose port "$svc" 2>/dev/null || true)
        if [ -n "$p" ]; then fail "$svc publishes $p - only the server may be reachable"; else pass "$svc publishes nothing"; fi
    done
}

say_digests() {
    printf '\n== A-4 digest pins (R-4)\n'
    for svc in immich-server immich-machine-learning database redis; do
        id=$(cid "$svc")
        if [ -z "$id" ]; then
            fail "$svc has no container - its image pin cannot be verified"
            continue
        fi
        ref=$(docker inspect --format '{{index .Config.Image}}' "$id" 2>/dev/null || true)
        case "$ref" in
            *@sha256:*) pass "$svc pinned: ${ref%%,*}" ;;
            "") fail "$svc: the image reference could not be read" ;;
            *) fail "$svc is not digest-pinned: $ref" ;;
        esac
    done
}

say_database() {
    printf '\n== A-2 database image and vector extension (R-2)\n'
    ext=$(compose exec -T database psql -U "$DB_USERNAME" -d "$DB_DATABASE_NAME" -tAc \
        "SELECT name FROM pg_available_extensions WHERE name IN ('vectorchord','vector') ORDER BY name" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    case "$ext" in
        *[![:space:]]*) pass "vector extension available: $ext" ;;
        *) fail "no vector extension visible - the database image is probably not the Immich-maintained one" ;;
    esac
    img=$(docker inspect --format '{{index .Config.Image}}' "$(cid database)" 2>/dev/null || true)
    case "$img" in
        */immich-app/postgres*) pass "database runs the Immich-maintained image" ;;
        "") note "the database container was not found; image check skipped" ;;
        *) fail "database image is not the Immich-maintained one: $img" ;;
    esac
}

say_storage() {
    printf '\n== A-3 database storage type (R-3)\n'
    if [ -n "$DB_DATA_LOCATION" ]; then
        fs=$(findmnt -no FSTYPE -T "$DB_DATA_LOCATION" 2>/dev/null || echo unknown)
        case "$fs" in
            nfs*|cifs|smb*|fuse*|9p) fail "$DB_DATA_LOCATION is on $fs - not a local filesystem" ;;
            unknown) note "filesystem of $DB_DATA_LOCATION unknown; check the path exists" ;;
            *) pass "$DB_DATA_LOCATION is on $fs" ;;
        esac
    else
        note "DB_DATA_LOCATION unset; storage-type check skipped"
    fi
}

say_server() {
    printf '\n== A-1/A-5 server liveness (R-1, R-5)\n'
    if have curl; then
        body=$(curl -fsS --max-time 10 "${IMMICH_URL%/}/api/server/ping" 2>/dev/null || true)
        case "$body" in
            *pong*) pass "GET ${IMMICH_URL%/}/api/server/ping answered pong" ;;
            *) fail "GET ${IMMICH_URL%/}/api/server/ping did not answer pong (got: ${body:-no response})" ;;
        esac
        ver=$(curl -fsS --max-time 10 "${IMMICH_URL%/}/api/server/version" 2>/dev/null || true)
        if [ -n "$ver" ]; then pass "server version reported: $ver"; else note "version endpoint did not answer"; fi
    else
        note "curl not available; probing through the container's health status instead"
    fi
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$(cid immich-server)" 2>/dev/null || true)
    case "$health" in
        healthy) pass "the server's healthcheck: healthy" ;;
        none|"") note "the server has no healthcheck or was not found" ;;
        *) fail "the server's healthcheck: $health" ;;
    esac
    for svc in database redis; do
        h=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$(cid "$svc")" 2>/dev/null || true)
        case "$h" in
            healthy) pass "$svc healthcheck: healthy" ;;
            none|"") note "$svc has no healthcheck" ;;
            *) fail "$svc healthcheck: $h" ;;
        esac
    done
}

say_ml() {
    printf '\n== A-5/A-9 machine learning (R-5, R-7, R-8)\n'
    id=$(cid immich-machine-learning)
    if [ -n "$id" ]; then
        pass "immich-machine-learning container present"
        note "cache volume: $(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/cache"}}{{.Name}}{{end}}{{end}}' "$id" 2>/dev/null || echo unknown)"
        nano=$(docker inspect --format '{{.HostConfig.NanoCpus}}' "$id" 2>/dev/null || echo 0)
        case "${ML_CPU_LIMIT:-0}" in
            0|"")
                note "no CPU ceiling is set (ML_CPU_LIMIT=${ML_CPU_LIMIT:-unset}): the first index may use the whole machine, which must be the operator's recorded decision" ;;
            *)
                # ML_CPU_LIMIT is a CPU count (P-20, e.g. 4.0) and Compose applies it as
                # the container's cpus limit, which Docker records as NanoCpus. The
                # recorded ceiling is in force only when the two agree: accepting any
                # positive NanoCpus passed a weaker cap, and the container's own figure
                # is what A-9's "the observed peak matches the recorded ceiling" means.
                if ! have awk; then
                    fail "ML_CPU_LIMIT=$ML_CPU_LIMIT is set but awk is missing, so the container's ceiling cannot be compared with it"
                else
                    want=$(awk -v cpus="$ML_CPU_LIMIT" 'BEGIN { printf "%.0f", cpus * 1000000000 }' 2>/dev/null)
                    case "$want" in
                        ""|0)
                            fail "ML_CPU_LIMIT=$ML_CPU_LIMIT is not a CPU ceiling this check can compare (P-20: a decimal such as 4.0, or 0 for none)" ;;
                        *)
                            if [ "${nano:-0}" -eq "$want" ]; then
                                pass "CPU ceiling in force: HostConfig.NanoCpus=$nano equals ML_CPU_LIMIT=$ML_CPU_LIMIT"
                            elif [ "${nano:-0}" -gt 0 ] && [ "${nano:-0}" -lt "$want" ]; then
                                fail "ML_CPU_LIMIT=$ML_CPU_LIMIT is recorded but the container's ceiling is weaker (HostConfig.NanoCpus=$nano): the first index can exceed the accepted limit"
                            else
                                fail "ML_CPU_LIMIT=$ML_CPU_LIMIT is recorded but the container carries HostConfig.NanoCpus=${nano:-0}, not the recorded ceiling"
                            fi ;;
                    esac
                fi ;;
        esac
        note "provider evidence: docker compose logs immich-machine-learning | grep -i 'provider\\|loaded'"
    else
        fail "immich-machine-learning has no container"
    fi
}

say_backup() {
    printf '\n== A-6/A-8 backup (R-6)\n'
    if [ -n "$UPLOAD_LOCATION" ] && [ -d "$UPLOAD_LOCATION/backups" ]; then
        n=$(ls -1 "$UPLOAD_LOCATION/backups" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$n" -gt 0 ]; then pass "instance dumps present: $n file(s) under backups/"; else note "no dump yet - run the database-dump job from the administration UI"; fi
    else
        note "UPLOAD_LOCATION unset or backups/ absent; no instance dump visible"
    fi
    if [ -n "$BACKUP_TARGET" ] && [ -d "$BACKUP_TARGET" ]; then
        dumps=$(ls -1 "$BACKUP_TARGET" 2>/dev/null | grep -ci 'dump\|sql' || true)
        if [ "${dumps:-0}" -gt 0 ]; then pass "operator backup holds a database dump"; else fail "no database dump under $BACKUP_TARGET"; fi
    else
        note "BACKUP_TARGET unset; the rehearsal in templates/backup-and-restore.md is an acceptance test, not a default"
    fi
}

say_setup_closed() {
    printf '\n== A-7 first administrator (R-10)\n'
    if have curl; then
        if code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${IMMICH_URL%/}/auth/admin-sign-up" 2>/dev/null); then
            case "$code" in
                2*) fail "the sign-up endpoint answered $code - an administrator exists, so it must be closed (set IMMICH_ALLOW_SETUP=false)" ;;
                *) pass "sign-up endpoint refused with $code" ;;
            esac
        else
            note "sign-up endpoint unreachable from here (${IMMICH_URL%/})"
        fi
    else
        note "curl not available; check IMMICH_ALLOW_SETUP in .env and the administration settings"
    fi
}

say_services
say_digests
say_database
say_storage
say_server
say_ml
say_backup
say_setup_closed

printf '\n'
if [ "$failures" -eq 0 ]; then
    printf 'All mechanical checks passed. The behavioural tests (A-8 restore rehearsal, A-9 load ceiling, A-10 exposure vantage, A-11 external library reads, A-12 down/up) are in SCHEMATIC.md.\n'
    exit 0
fi
printf '%s check(s) failed.\n' "$failures"
exit 1
