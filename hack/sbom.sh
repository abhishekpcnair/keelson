#!/usr/bin/env bash
# Make one CycloneDX SBOM for each upstream image in images.json (from hack/list_images.py).
#
# Usage: hack/sbom.sh <images.json> <out-dir> [parallel]
# Writes <out-dir>/<module>/<image-name>.cdx.json. An image that several modules use is
# scanned once and copied. Needs `syft` (pinned in the release workflow) and `jq`.
# Fails, with the image names, when an image cannot be scanned. It never skips an image.
set -euo pipefail

json=${1:?usage: sbom.sh <images.json> <out-dir> [parallel]}
out=${2:?usage: sbom.sh <images.json> <out-dir> [parallel]}
parallel=${3:-4}
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

name_of() { local n=$1; n=${n//\//_}; n=${n//:/_}; echo "${n//@/_}"; }

# "<module> <image>" pairs. The first module of an image does the scan.
jq -r 'to_entries[] | .key as $m | .value[] | "\($m) \(.)"' "$json" | sort -u > "$work/pairs"
sort -u -k2,2 "$work/pairs" > "$work/scans"

scan() {   # scan <module> <image>
  local dir="$2/$1" file
  mkdir -p "$dir"
  file="$dir/$(name_of "$3").cdx.json"
  if syft "$3" --platform linux/amd64 -o cyclonedx-json="$file" -q; then
    echo "sbom: $3"
  else
    echo "FAIL sbom: $3" >&2; rm -f "$file"; return 1
  fi
}
export -f scan name_of

# Time is the risk (#61): log it, so the release notes can record it.
start=$SECONDS
xargs -P "$parallel" -L 1 bash -c 'scan "$0" "'"$out"'" "$1"' < "$work/scans" || { echo "sbom: some images failed" >&2; exit 1; }

# Copy each SBOM to the other modules that use the same image.
while read -r module image; do
  dest="$out/$module/$(name_of "$image").cdx.json"
  [ -f "$dest" ] && continue
  src=$(find "$out" -name "$(name_of "$image").cdx.json" | head -n1)
  mkdir -p "$out/$module" && cp "$src" "$dest"
done < "$work/pairs"

echo "sbom: $(wc -l < "$work/scans" | tr -d ' ') image(s) scanned in $((SECONDS - start))s"
