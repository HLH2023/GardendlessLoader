#!/usr/bin/env bash
# Build an APK with the save-server address injected at compile time.
#
# The address is never committed. It lives in .env.local (gitignored, one
# `PVZGE_SERVER=…` line) and is passed to the Dart compiler as
# --dart-define=PVZGE_SERVER=…, which is what lib/src/constants.dart reads.
#
# Usage: tools/build-apk.sh [extra flutter build args, e.g. --debug]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${PVZGE_ENV_FILE:-$repo_root/.env.local}"

if [[ ! -f "$env_file" ]]; then
  echo "error: $env_file not found." >&2
  echo "Create it with one line (it is gitignored):" >&2
  echo "  PVZGE_SERVER=https://your-save-server.example" >&2
  exit 1
fi

# Read the value without sourcing the file: nothing in it is executed.
server="$(
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*PVZGE_SERVER[[:space:]]*=/ {
      sub(/^[[:space:]]*PVZGE_SERVER[[:space:]]*=[[:space:]]*/, "")
      gsub(/^["\047]/, "")
      gsub(/["\047][[:space:]]*$/, "")
      sub(/[[:space:]]+$/, "")
      value = $0
    }
    END { print value }
  ' "$env_file"
)"

if [[ -z "${server}" ]]; then
  echo "error: PVZGE_SERVER is missing or empty in $env_file" >&2
  exit 1
fi

case "$server" in
  https://*) ;;
  http://localhost* | http://127.0.0.1*) ;;
  *)
    echo "error: PVZGE_SERVER must start with https:// (http:// only for localhost)" >&2
    exit 1
    ;;
esac

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter is not on PATH" >&2
  exit 1
fi

echo "Building APK with PVZGE_SERVER=https://***"
cd "$repo_root"
exec flutter build apk --release --dart-define=PVZGE_SERVER="$server" "$@"
