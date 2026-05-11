#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: fake-binary-cache.sh [options] STORE_PATH...

Create a temporary fake local store where each listed store path is an empty
directory, then serve it as an HTTP binary cache via `nix serve`.

Options:
  --paths-file FILE      Read additional store paths from FILE (one per line)
  --listen-address ADDR  Address for nix serve (default: 127.0.0.1)
  --port PORT            Port for nix serve (default: 8080)
  --port-file FILE       Write chosen port to FILE
  --priority N           Cache priority
  -h, --help             Show this help

Notes:
  - This intentionally creates invalid substitutes and can break software.
  - Set KEEP_FAKE_STORE_ROOT=1 to keep the temporary store for debugging.
EOF
}

listen_address="127.0.0.1"
port="8080"
port_file=""
priority=""
paths_file=""
declare -a store_paths=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --paths-file)
            [[ $# -ge 2 ]] || { echo "error: --paths-file requires an argument" >&2; exit 1; }
            paths_file="$2"
            shift 2
            ;;
        --listen-address)
            [[ $# -ge 2 ]] || { echo "error: --listen-address requires an argument" >&2; exit 1; }
            listen_address="$2"
            shift 2
            ;;
        --port)
            [[ $# -ge 2 ]] || { echo "error: --port requires an argument" >&2; exit 1; }
            port="$2"
            shift 2
            ;;
        --port-file)
            [[ $# -ge 2 ]] || { echo "error: --port-file requires an argument" >&2; exit 1; }
            port_file="$2"
            shift 2
            ;;
        --priority)
            [[ $# -ge 2 ]] || { echo "error: --priority requires an argument" >&2; exit 1; }
            priority="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            store_paths+=("$@")
            break
            ;;
        -*)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            store_paths+=("$1")
            shift
            ;;
    esac
done

if [[ -n "$paths_file" ]]; then
    if [[ ! -f "$paths_file" ]]; then
        echo "error: paths file not found: $paths_file" >&2
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        store_paths+=("$line")
    done < "$paths_file"
fi

if [[ ${#store_paths[@]} -eq 0 && ! -t 0 ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        store_paths+=("$line")
    done
fi

if [[ ${#store_paths[@]} -eq 0 ]]; then
    echo "error: no store paths provided" >&2
    usage >&2
    exit 1
fi

declare -A unique_store_paths=()
store_dir=""
for store_path in "${store_paths[@]}"; do
    if [[ ! "$store_path" =~ ^(.+)/([0-9abcdfghijklmnpqrsvwxyz]{32}-[^/]+)$ ]]; then
        echo "error: invalid store path: $store_path" >&2
        exit 1
    fi

    path_store_dir="${BASH_REMATCH[1]}"
    if [[ -z "$store_dir" ]]; then
        store_dir="$path_store_dir"
    elif [[ "$store_dir" != "$path_store_dir" ]]; then
        echo "error: all store paths must use the same store dir (got '$store_dir' and '$path_store_dir')" >&2
        exit 1
    fi

    unique_store_paths["$store_path"]=1
done

root="$(mktemp -d -t nix-fake-binary-cache.XXXXXXXXXX)"
cleanup() {
    if [[ "${KEEP_FAKE_STORE_ROOT:-0}" != "1" ]]; then
        rm -rf "$root"
    else
        echo "keeping fake store root: $root" >&2
    fi
}
trap cleanup EXIT

NIX_STORE_DIR="$store_dir" nix-store --store "local?root=$root" --init

empty_dir="$(mktemp -d -p "$root" empty.XXXXXXXXXX)"
empty_nar_hash="$(nix hash path --type sha256 --base16 "$empty_dir")"
empty_nar_size=$(( $(wc -c < <(nix-store --dump "$empty_dir")) ))
rm -rf "$empty_dir"

registration_file="$(mktemp -p "$root" registration.XXXXXXXXXX)"
for store_path in "${!unique_store_paths[@]}"; do
    base_name="${store_path##*/}"
    mkdir -p "$root$store_dir/$base_name"
    printf '%s\n%s\n%s\n\n0\n' \
        "$store_path" \
        "$empty_nar_hash" \
        "$empty_nar_size" >> "$registration_file"
done
printf '\n' >> "$registration_file"

NIX_STORE_DIR="$store_dir" nix-store \
    --store "local?root=$root" \
    --register-validity \
    --hash-given < "$registration_file"

echo "warning: serving fake empty substitutes; this can break software." >&2
echo "fake store root: $root" >&2

serve_args=(
    serve
    --store "local?root=$root"
    --listen-address "$listen_address"
    --port "$port"
)

if [[ -n "$port_file" ]]; then
    serve_args+=(--port-file "$port_file")
fi

if [[ -n "$priority" ]]; then
    serve_args+=(--priority "$priority")
fi

exec NIX_STORE_DIR="$store_dir" nix "${serve_args[@]}"
