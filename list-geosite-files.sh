#!/usr/bin/env bash
set -euo pipefail

REPO="MetaCubeX/meta-rules-dat"
BRANCH="sing"
OUT_FILE="${1:-list.txt}"
API_BASE="https://api.github.com/repos/${REPO}"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required. Install jq and run again." >&2
  exit 1
fi

fetch_json() {
  local url="$1"
  curl -fsSL "$url"
}

# 1) Resolve branch -> commit SHA
ref_json="$(fetch_json "${API_BASE}/git/ref/heads/${BRANCH}")"
commit_sha="$(jq -r '.object.sha // empty' <<<"$ref_json")"

if [[ -z "$commit_sha" ]]; then
  echo "Error: failed to resolve branch SHA for ${BRANCH}" >&2
  exit 1
fi

# 2) Commit -> root tree SHA
commit_json="$(fetch_json "${API_BASE}/git/commits/${commit_sha}")"
root_tree_sha="$(jq -r '.tree.sha // empty' <<<"$commit_json")"

if [[ -z "$root_tree_sha" ]]; then
  echo "Error: failed to resolve root tree SHA" >&2
  exit 1
fi

# 3) root -> geo tree SHA
root_tree_json="$(fetch_json "${API_BASE}/git/trees/${root_tree_sha}")"
geo_tree_sha="$(jq -r '.tree[] | select(.path=="geo" and .type=="tree") | .sha' <<<"$root_tree_json")"

if [[ -z "$geo_tree_sha" ]]; then
  echo "Error: failed to find geo directory" >&2
  exit 1
fi

# 4) geo -> geosite tree SHA
geo_tree_json="$(fetch_json "${API_BASE}/git/trees/${geo_tree_sha}")"
geosite_tree_sha="$(jq -r '.tree[] | select(.path=="geosite" and .type=="tree") | .sha' <<<"$geo_tree_json")"

if [[ -z "$geosite_tree_sha" ]]; then
  echo "Error: failed to find geo/geosite directory" >&2
  exit 1
fi

# 5) List files directly in geo/geosite
geosite_tree_json="$(fetch_json "${API_BASE}/git/trees/${geosite_tree_sha}")"

if jq -e '.truncated == true' >/dev/null <<<"$geosite_tree_json"; then
  echo "Warning: geosite tree response is truncated; list may be incomplete." >&2
fi

jq -r '.tree[] | select(.type=="blob") | .path' <<<"$geosite_tree_json" | sort -u > "$OUT_FILE"

count="$(wc -l < "$OUT_FILE" | tr -d ' ')"
echo "Saved ${count} file names to ${OUT_FILE}"
