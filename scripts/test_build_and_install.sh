#!/bin/zsh
set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"

compare_releases() {
  awk -v candidate_version="$1" -v candidate_build="$2" \
    -v installed_version="$3" -v installed_build="$4" \
    -f "$script_root/compare_releases.awk"
}

[[ "$(compare_releases 1.60 76 1.60 76)" == "0" ]]
[[ "$(compare_releases 1.61 1 1.60 76)" == "1" ]]
[[ "$(compare_releases 1.60 77 1.60 76)" == "1" ]]
[[ "$(compare_releases 1.59 99 1.60 76)" == "-1" ]]
[[ "$(compare_releases 1.60 75 1.60 76)" == "-1" ]]

if compare_releases 1.x 1 1.60 76 >/dev/null 2>&1; then
  echo "Malformed release was accepted." >&2
  exit 1
fi

echo "Release comparison checks passed."
