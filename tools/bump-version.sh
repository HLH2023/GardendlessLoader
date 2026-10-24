#!/usr/bin/env bash
# Bump the personal build of this fork and keep versionCode in step.
#
# Version scheme (personal builds must be distinguishable from upstream):
#
#   versionName = MAJOR.MINOR.PATCH-hlh.N     e.g. 0.9.0-hlh.1
#   versionCode = MAJOR*1_000_000 + MINOR*10_000 + PATCH*100 + N
#
#   0.9.0-hlh.1  ->      0 + 90000 +   0 + 1 =   90001
#   0.9.0-hlh.2  ->                                 90002
#   0.9.1-hlh.1  ->      0 + 90000 + 100 + 1 =   90101
#   0.10.0-hlh.1 ->      0 + 100000 +   0 + 1 = 100001
#   1.0.0-hlh.1  -> 1000000 + 0     +   0 + 1 = 1000001
#
# The numeric triple is the upstream release; only N moves on a bump. When the
# version has no `-hlh.N` yet (a fresh upstream sync), `-hlh.1` is inserted and
# the code is computed with N = 1. `major` starts at 0 here, which keeps 0.x
# codes below 1.0.0 codes; the scheme assumes MAJOR < 1000, MINOR < 100,
# PATCH < 100 and N < 100, and refuses to write an ambiguous version.
#
# Only pubspec.yaml is touched. Running it twice bumps twice by design.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pubspec="$repo_root/pubspec.yaml"

if [[ ! -f "$pubspec" ]]; then
  echo "error: $pubspec not found" >&2
  exit 1
fi

# The first `version:` line is the one pub/Flutter reads.
line_no="$(grep -nE '^version:[[:space:]]*' "$pubspec" | head -n1 | cut -d: -f1 || true)"
if [[ -z "${line_no}" ]]; then
  echo "error: no version: line in $pubspec" >&2
  exit 1
fi

raw="$(sed -n "${line_no}p" "$pubspec" | sed -E 's/^version:[[:space:]]*//' | tr -d "\"'[:space:]")"
old_raw="$raw"

# Split `X.Y.Z[-pre][+code]` into the name and the optional build number.
old_name="${raw%%+*}"
old_code_field=""
if [[ "$raw" == *"+"* ]]; then
  old_code_field="${raw##*+}"
fi

if [[ ! "$old_name" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-.*)?$ ]]; then
  echo "error: version '$old_name' is not MAJOR.MINOR.PATCH[-tag]" >&2
  exit 1
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
prerelease="${BASH_REMATCH[4]:-}"

# Continue the personal series when there is one; otherwise start at 1.
if [[ "$prerelease" =~ ^-hlh\.([0-9]+)$ ]]; then
  personal="${BASH_REMATCH[1]}"
  new_personal=$((personal + 1))
else
  personal=0
  new_personal=1
fi

if (( new_personal >= 100 )); then
  echo "error: personal build $new_personal would collide with the patch digit;" >&2
  echo "       move to the next patch release by hand (e.g. 0.9.1-hlh.1)." >&2
  exit 1
fi
if (( major >= 1000 || minor >= 100 || patch >= 100 )); then
  echo "error: $major.$minor.$patch does not fit the versionCode scheme" >&2
  echo "       (requires MAJOR < 1000, MINOR < 100, PATCH < 100)" >&2
  exit 1
fi

new_name="${major}.${minor}.${patch}-hlh.${new_personal}"
new_code=$(( major * 1000000 + minor * 10000 + patch * 100 + new_personal ))

# versionCode must move forward, never repeat or regress.
if [[ -n "$old_code_field" ]]; then
  if [[ ! "$old_code_field" =~ ^[0-9]+$ ]]; then
    echo "error: build number '$old_code_field' in $pubspec is not numeric" >&2
    exit 1
  fi
  old_code="$old_code_field"
else
  # Flutter's default versionCode is 1 when the pubspec carries no `+build`.
  old_code=1
fi

if (( new_code <= old_code )); then
  echo "error: new versionCode $new_code is not greater than the current $old_code" >&2
  exit 1
fi

tmp="$(mktemp "${pubspec}.XXXXXX")"
awk -v target="$line_no" -v repl="version: ${new_name}+${new_code}" \
  'NR == target { print repl; next } { print }' "$pubspec" > "$tmp"
mv "$tmp" "$pubspec"

echo "versionName: ${old_name} -> ${new_name}"
echo "versionCode: ${old_code} -> ${new_code}"
echo "pubspec:     $pubspec (was ${old_raw})"
