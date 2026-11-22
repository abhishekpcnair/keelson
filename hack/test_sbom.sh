#!/usr/bin/env bash
# Offline test for hack/sbom.sh with a stub `syft`. Run: hack/test_sbom.sh
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/syft" <<'STUB'
#!/usr/bin/env bash
# stub: syft registry:<image> --platform P -o cyclonedx-json=<file> -q ; fails for any image named *bad*
case "$1" in *bad*) exit 1 ;; esac
image=${1#registry:}
for a in "$@"; do case "$a" in cyclonedx-json=*) echo "{\"image\": \"$image\"}" > "${a#cyclonedx-json=}" ;; esac; done
STUB
chmod +x "$tmp/bin/syft"
export PATH="$tmp/bin:$PATH"

echo '{"a": ["ghcr.io/x/one:1", "ghcr.io/x/shared:2"], "b": ["ghcr.io/x/shared:2"]}' > "$tmp/images.json"
hack/sbom.sh "$tmp/images.json" "$tmp/out" 2 > /dev/null
for f in a/ghcr.io_x_one_1 a/ghcr.io_x_shared_2 b/ghcr.io_x_shared_2; do
  [ -s "$tmp/out/$f.cdx.json" ] || { echo "FAIL: missing $f.cdx.json"; exit 1; }
done

[ "$(wc -l < "$tmp/out/unique.txt" | tr -d ' ')" = 2 ] || { echo "FAIL: unique.txt should list 2 images"; exit 1; }

echo '{}' > "$tmp/empty.json"
if err=$(hack/sbom.sh "$tmp/empty.json" "$tmp/out3" 2>&1 >/dev/null); then echo "FAIL: an empty list should fail"; exit 1; fi
echo "$err" | grep -q 'lists no images' || { echo "FAIL: empty list error text"; exit 1; }

echo '{"a": ["ghcr.io/x/ok:1", "ghcr.io/x/bad:1"]}' > "$tmp/images.json"
if err=$(hack/sbom.sh "$tmp/images.json" "$tmp/out2" 2 2>&1 >/dev/null); then echo "FAIL: a bad image should fail"; exit 1; fi
echo "$err" | grep -q 'ghcr.io/x/bad:1' || { echo "FAIL: error does not name the image"; exit 1; }
echo "test_sbom: ok"
