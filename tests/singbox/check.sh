#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image="${TEST_IMAGE:-subconverter-singbox-test:local}"
keep_image="${KEEP_IMAGE:-0}"
output_dir="${OUTPUT_DIR:-}"
template_url="https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash/config/ACL4SSR_Online_Mini.ini"
singbox_versions=(1.12.25 1.14.4)
mihomo_image="metacubex/mihomo:v1.19.34"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/subconverter-singbox-check.XXXXXX")"
run_id="$$-${RANDOM}"
subconverter_name="subconverter-singbox-check-${run_id}"
http_pid=""
subconverter_started=0
failures=0
declare -a pulled_images=()

cleanup() {
    if [[ "$subconverter_started" == "1" ]]; then
        docker stop "$subconverter_name" >/dev/null 2>&1 || true
    fi
    if [[ -n "$http_pid" ]]; then
        kill "$http_pid" >/dev/null 2>&1 || true
        wait "$http_pid" >/dev/null 2>&1 || true
    fi
    for pulled_image in "${pulled_images[@]}"; do
        docker image rm "$pulled_image" >/dev/null 2>&1 || true
    done
    if [[ "$keep_image" != "1" ]]; then
        docker image rm "$image" >/dev/null 2>&1 || true
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$work_dir/bin" "$work_dir/responses" "$work_dir/logs" "$work_dir/mihomo-data"
cp "$root/tests/singbox/fixture.json" "$work_dir/fixture.json"

if [[ "$(uname -m)" != "x86_64" ]]; then
    printf 'This check requires an x86_64 host.\n' >&2
    exit 1
fi

for singbox_version in "${singbox_versions[@]}"; do
    archive="$work_dir/sing-box-${singbox_version}-linux-amd64.tar.gz"
    directory="$work_dir/sing-box-${singbox_version}"
    curl --silent --show-error --fail --location \
        "https://github.com/SagerNet/sing-box/releases/download/v${singbox_version}/sing-box-${singbox_version}-linux-amd64.tar.gz" \
        --output "$archive"
    mkdir -p "$directory"
    tar --extract --gzip --file "$archive" --directory "$directory"
    install -m 0755 "$directory/sing-box-${singbox_version}-linux-amd64/sing-box" \
        "$work_dir/bin/sing-box-${singbox_version}"
done

if ! docker image inspect "$mihomo_image" >/dev/null 2>&1; then
    docker pull "$mihomo_image"
    pulled_images+=("$mihomo_image")
fi

docker build \
    --file "$root/scripts/Dockerfile" \
    --build-arg UPDATE_RULES=false \
    --tag "$image" \
    "$root"

http_port="$(python3 - <<'PY'
import socket

with socket.socket() as sock:
    sock.bind(("", 0))
    print(sock.getsockname()[1])
PY
)"
subconverter_port="$(python3 - <<'PY'
import socket

with socket.socket() as sock:
    sock.bind(("", 0))
    print(sock.getsockname()[1])
PY
)"

python3 -m http.server "$http_port" --bind 0.0.0.0 --directory "$work_dir" \
    >"$work_dir/logs/fixture-http.log" 2>&1 &
http_pid=$!

for _ in $(seq 1 40); do
    if curl --silent --fail "http://127.0.0.1:${http_port}/fixture.json" >/dev/null; then
        break
    fi
    sleep 0.25
done
curl --silent --fail "http://127.0.0.1:${http_port}/fixture.json" >/dev/null

docker run --detach --rm \
    --name "$subconverter_name" \
    --add-host=host.docker.internal:host-gateway \
    --publish "127.0.0.1:${subconverter_port}:25500" \
    "$image" >/dev/null
subconverter_started=1

for _ in $(seq 1 120); do
    if curl --silent --fail --max-time 1 \
        "http://127.0.0.1:${subconverter_port}/version" >/dev/null; then
        break
    fi
    sleep 0.5
done
curl --silent --fail --max-time 1 \
    "http://127.0.0.1:${subconverter_port}/version" >/dev/null

fetch_output() {
    local case_name="$1"
    local target="$2"
    local include_template="$3"
    local output="$work_dir/responses/${case_name}.out"
    local curl_log="$work_dir/logs/fetch-${case_name}.log"
    local -a args=(
        --silent
        --show-error
        --location
        --fail
        --max-time 120
        --get
        --output "$output"
        --data-urlencode "target=${target}"
        --data-urlencode "url=http://host.docker.internal:${http_port}/fixture.json"
        --data-urlencode "add_emoji=false"
        --data-urlencode "remove_emoji=false"
    )

    if [[ "$case_name" == "surge4" ]]; then
        args+=(--data-urlencode "ver=4")
    fi
    if [[ "$include_template" == "yes" ]]; then
        args+=(--data-urlencode "config=${template_url}")
    fi

    curl "${args[@]}" "http://127.0.0.1:${subconverter_port}/sub" 2>"$curl_log"
}

fetch_output "clash" "clash" "no"
fetch_output "singbox" "singbox" "no"
fetch_output "surge4" "surge" "no"
fetch_output "quanx" "quanx" "no"
fetch_output "loon" "loon" "no"
fetch_output "surfboard" "surfboard" "no"
fetch_output "clash-template" "clash" "yes"
fetch_output "singbox-template" "singbox" "yes"

first_failure_line() {
    local log="$1"
    local line

    line="$(sed $'s/\033\\[[0-9;]*m//g' "$log" | grep -m 1 'FATAL' || true)"
    if [[ -z "$line" ]]; then
        line="$(sed $'s/\033\\[[0-9;]*m//g' "$log" | grep -m 1 'level=error' || true)"
    fi
    if [[ -z "$line" ]]; then
        line="$(sed $'s/\033\\[[0-9;]*m//g' "$log" | awk 'NF { print; exit }')"
    fi
    printf '%s\n' "$line"
}

check_singbox_protocols() {
    local case_name="$1"
    local output="$work_dir/responses/${case_name}.out"

    for marker in FIXTURE-SS FIXTURE-VMESS FIXTURE-ANYTLS FIXTURE-TUIC; do
        if ! grep --fixed-strings --quiet "$marker" "$output"; then
            printf 'FAIL\tdropped output for %s in %s\n' "$marker" "$case_name" \
                | tee -a "$work_dir/results.tsv"
            failures=$((failures + 1))
            return
        fi
    done
    printf 'PASS\tall fixture proxies present in %s\n' "$case_name" \
        | tee -a "$work_dir/results.tsv"
}

check_singbox() {
    local validator_version="$1"
    local case_name="$2"
    local log="$work_dir/logs/${validator_version}-${case_name}.log"

    if "$work_dir/bin/sing-box-${validator_version}" check \
        -c "$work_dir/responses/${case_name}.out" \
        >"$log" 2>&1; then
        printf 'PASS\tsing-box %s\t%s\n' "$validator_version" "$case_name" \
            | tee -a "$work_dir/results.tsv"
    else
        printf 'FAIL\tsing-box %s\t%s\t%s\n' \
            "$validator_version" "$case_name" "$(first_failure_line "$log")" \
            | tee -a "$work_dir/results.tsv"
        failures=$((failures + 1))
    fi
}

check_mihomo() {
    local case_name="$1"
    local log="$work_dir/logs/mihomo-${case_name}.log"

    if docker run --rm \
        --volume "$work_dir:/work" \
        "$mihomo_image" -t -d /work/mihomo-data -f "/work/responses/${case_name}.out" \
        >"$log" 2>&1; then
        printf 'PASS\tmihomo 1.19.34\t%s\n' "$case_name" \
            | tee -a "$work_dir/results.tsv"
    else
        printf 'FAIL\tmihomo 1.19.34\t%s\t%s\n' \
            "$case_name" "$(first_failure_line "$log")" \
            | tee -a "$work_dir/results.tsv"
        failures=$((failures + 1))
    fi
}

: >"$work_dir/results.tsv"
check_singbox_protocols "singbox"
check_singbox_protocols "singbox-template"
check_singbox "1.12.25" "singbox"
check_singbox "1.12.25" "singbox-template"
check_singbox "1.14.4" "singbox"
check_singbox "1.14.4" "singbox-template"
check_mihomo "clash"
check_mihomo "clash-template"

printf '\nResult matrix:\n'
cat "$work_dir/results.tsv"

if [[ -n "$output_dir" ]]; then
    mkdir -p "$output_dir"
    cp -R "$work_dir/responses" "$work_dir/logs" "$work_dir/results.tsv" "$output_dir/"
    printf 'Artifacts copied to %s\n' "$output_dir"
fi

if ((failures > 0)); then
    printf '\n%d check(s) failed.\n' "$failures"
    exit 1
fi

printf '\nAll checks passed.\n'
