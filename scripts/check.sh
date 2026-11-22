
#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
job="hw3test_$(date +%s)_$$"
export HOST_PORT=0
n=3
step="start"

run() {
    docker compose -p "$job" "$@"
}

error() {
    echo "Error at $step: $1" >&2
    exit 1
}

finish() {
    run down -v --remove-orphans >/dev/null 2>&1 || true
}

trap finish 0
trap 'exit 130' INT
trap 'exit 143' TERM

http() {
    curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 2 --max-time 5 "$@"
}

port_from_docker() {
    address=$(run port app 8000) || error "can't get port"
    port=${address##*:}
    case "$port" in
        ''|*[!0-9]*) error "bad port: $address" ;;
    esac
    url="http://127.0.0.1:$port"
}

wait_app() {
    i=0
    while [ "$i" -lt 90 ]; do
        if [ "$(http "$url/readyz" || true)" = 200 ]; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    error "app didn't become ready"
}

count() {
    answer=$(curl -fsS --connect-timeout 2 --max-time 5 "$url/") || error "GET / failed"
    printf '%s\n' "$answer" | sed -n 's/.*"count"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

check_count() {
    got=$(count) || error "can't read count"
    [ "$got" = "$1" ] || error "expected $1, got $got"
}

echo "Testing project $job"
run up -d --build || error "can't start containers"
port_from_docker
wait_app

step="increments"
check_count 0
i=0
while [ "$i" -lt "$n" ]; do
    [ "$(http -X POST "$url/increment")" = 200 ] || error "POST failed"
    i=$((i + 1))
done
check_count "$n"
echo "OK: increment"

step="recreate app"
run up -d --force-recreate --no-deps app || error "can't recreate app"
port_from_docker
wait_app
check_count "$n"
echo "OK: recreate app"

step="redis off"
run stop redis || error "can't stop redis"
[ "$(http "$url/healthz")" = 200 ] || error "healthz should be 200"
[ "$(http "$url/readyz")" = 503 ] || error "readyz should be 503"
[ "$(http -X POST "$url/increment")" = 503 ] || error "POST should be 503"
echo "OK: redis stopped"

step="redis on"
run start redis || error "can't start redis"
wait_app
check_count "$n"
[ "$(http -X POST "$url/increment")" = 200 ] || error "POST failed after restart"
check_count "$((n + 1))"
echo "OK: redis restarted"

step="backup"
redis_id=$(run ps -q redis) || error "can't find redis"
vol=$(docker inspect "$redis_id" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}') || error "can't find volume"

[ -n "$vol" ] || error "empty volume"

run stop app redis || error "can't stop services"

mkdir -p backups
docker run --rm \
    -v "$vol:/data:ro" \
    -v "$(pwd)/backups:/out" \
    -e FILE="$job.tar" \
    redis:7.4-alpine sh -c 'cd /data && tar -cf "/out/$FILE" .' \
    || error "can't make backup"

[ -s "backups/$job.tar" ] || error "backup is empty"

echo "OK: backup in backups/$job.tar"
echo "ALL CHECKS PASSED"

