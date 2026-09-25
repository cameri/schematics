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
#   HTTP_PORT         server port (default 2283)
#   EXPOSURE          private | localhost | tsdproxy | cloudflare (default private)
#   DB_USERNAME       database role (default postgres)
#   DB_DATABASE_NAME  database name (default immich)
#   UPLOAD_LOCATION   host path mounted at /data
#   DB_DATA_LOCATION  host path holding the cluster
#   BACKUP_TARGET     where the operator's backup is written
#   ML_CPU_LIMIT      recorded accepted ceiling, reported only

set -u

COMPOSE_DIR=${1:-${COMPOSE_DIR:-.}}
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
    published=$(compose port immich-server "$HTTP_PORT" 2>/dev/null || true)
    case "$EXPOSURE" in
        localhost)
            if [ -n "$published" ]; then pass "server port published: $published"; else fail "EXPOSURE=localhost but nothing is published on $HTTP_PORT"; fi ;;
        *)
            if [ -n "$published" ]; then note "server port published: $published"; else pass "no published port (EXPOSURE=$EXPOSURE)"; fi ;;
    esac
    for svc in database redis immich-machine-learning; do
        p=$(compose port "$svc" 2>/dev/null || true)
        if [ -n "$p" ]; then fail "$svc publishes $p - only the server may be reachable"; else pass "$svc publishes nothing"; fi
    done
}

say_digests() {
    printf '\n== A-4 digest pins (R-4)\n'
    for name in immich_server immich_machine_learning immich_postgres immich_redis; do
        ref=$(docker inspect --format '{{index .Config.Image}}' "$name" 2>/dev/null || true)
        if [ -z "$ref" ]; then
            note "$name: container not found (name it as the skeleton does, or skip)"
            continue
        fi
        case "$ref" in
            *@sha256:*) pass "$name pinned: ${ref%%,*}" ;;
            *) fail "$name is not digest-pinned: $ref" ;;
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
    img=$(docker inspect --format '{{index .Config.Image}}' immich_postgres 2>/dev/null || true)
    case "$img" in
        */immich-app/postgres*) pass "database runs the Immich-maintained image" ;;
        "") note "immich_postgres not found; image check skipped" ;;
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
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' immich_server 2>/dev/null || true)
    case "$health" in
        healthy) pass "immich_server healthcheck: healthy" ;;
        none|"") note "immich_server has no healthcheck or was not found" ;;
        *) fail "immich_server healthcheck: $health" ;;
    esac
    for c in immich_postgres immich_redis; do
        h=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || true)
        case "$h" in
            healthy) pass "$c healthcheck: healthy" ;;
            none|"") note "$c has no healthcheck" ;;
            *) fail "$c healthcheck: $h" ;;
        esac
    done
}

say_ml() {
    printf '\n== A-5/A-9 machine learning (R-5, R-7, R-8)\n'
    if docker inspect immich_machine_learning >/dev/null 2>&1; then
        pass "immich_machine_learning container present"
        note "cache: $(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/cache"}}{{.Name}}{{end}}{{end}}' immich_machine_learning 2>/dev/null || echo unknown)"
        note "cpu ceiling recorded by the operator: ${ML_CPU_LIMIT:-unset}"
        note "provider evidence: docker compose logs immich-machine-learning | grep -i 'provider\\|loaded'"
    else
        fail "immich_machine_learning container not found"
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
                2*) note "sign-up endpoint answered $code - open only while no administrator exists" ;;
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
