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

# The personal build number lives in pubspec.yaml as `X.Y.Z-hlh.N+CODE`;
# `tools/bump-version.sh` moves it forward. It is passed explicitly so the APK
# carries exactly the versionCode the release script compares against.
pubspec="$repo_root/pubspec.yaml"
version="$(grep -E '^version:[[:space:]]*' "$pubspec" | head -n1 | sed -E 's/^version:[[:space:]]*//' | tr -d "\"'[:space:]")"
if [[ -z "$version" ]]; then
  echo "error: no version: line in $pubspec" >&2
  exit 1
fi
if [[ "$version" != *"+"* ]]; then
  echo "error: pubspec version '$version' has no +versionCode." >&2
  echo "Run tools/bump-version.sh to stamp a personal build first." >&2
  exit 1
fi
version_name="${version%%+*}"
version_code="${version##*+}"
if [[ ! "$version_code" =~ ^[0-9]+$ ]]; then
  echo "error: versionCode '$version_code' in $pubspec is not numeric" >&2
  exit 1
fi

echo "Building APK with PVZGE_SERVER=https://***"
echo "versionName: $version_name"
echo "versionCode: $version_code"
cd "$repo_root"
exec flutter build apk --release \
  --build-name "$version_name" \
  --build-number "$version_code" \
  --dart-define=PVZGE_SERVER="$server" "$@"
