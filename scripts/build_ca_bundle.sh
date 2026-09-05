#!/bin/bash
# Build VisionRemotePS5/Resources/cacert.pem for the library's curl (mbedTLS, no system store).
# Mozilla's root bundle + the PSN intermediates: some PSN push servers
# (*-pushcl.np.communication.playstation.net) send only the leaf certificate, and mbedTLS
# cannot fetch the missing intermediate, so it is shipped as a trust anchor here.
set -e
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$PROJECT_DIR/VisionRemotePS5/Resources/cacert.pem"
WORK="${CA_WORK_DIR:-/tmp/ca-bundle-visionos}"
mkdir -p "$WORK"
curl -sL --max-time 60 -o "$WORK/mozilla.pem" https://curl.se/ca/cacert.pem
HOST="mobile-pushcl.np.communication.playstation.net"
echo | openssl s_client -connect "$HOST:443" -servername "$HOST" -showcerts 2>/dev/null > "$WORK/chain.txt"
# Split the served chain and append everything except the leaf (index 0) as trust anchors.
cp "$WORK/mozilla.pem" "$OUT"
python3 - "$WORK/chain.txt" "$OUT" "$HOST" <<'PY'
import re, sys, subprocess
chain, out, host = sys.argv[1], sys.argv[2], sys.argv[3]
blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", open(chain).read(), re.S)
with open(out, "a") as f:
    for pem in blocks[1:]:
        subject = subprocess.run(["openssl", "x509", "-noout", "-subject"], input=pem, capture_output=True, text=True).stdout.strip()
        f.write("\n# PSN intermediate (served by %s; the *-pushcl push servers omit it)\n%s\n%s\n" % (host, subject, pem))
print("appended %d intermediate(s)" % max(0, len(blocks) - 1))
PY
echo "wrote $OUT ($(grep -c 'BEGIN CERTIFICATE' "$OUT") certificates)"
