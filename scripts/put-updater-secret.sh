#!/usr/bin/env bash
# Give the scheduled keeper Worker its one secret: the dedicated UPDATER key.
#
#   ./scripts/put-updater-secret.sh
#
# Run by the Cloudflare account owner, once, after `npx wrangler login`. The key
# goes from contracts/.env straight into `wrangler secret put` on stdin: it is
# never printed, never held in a shell variable and never on a command line, and
# Cloudflare stores it encrypted, readable only by the Worker.
#
# It refuses any key but UPDATER_PRIVATE_KEY, and refuses if that key is the
# deployer's. The updater can only publish testnet prices within the feeds'
# on-chain bounds; the deployer owns every contract and must never leave this
# machine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/contracts/.env"
[ -f "$ENV_FILE" ] || { echo "contracts/.env missing"; exit 1; }

ENV_FILE="$ENV_FILE" python - <<'PY' || exit 1
import os, re, sys
text = open(os.environ["ENV_FILE"]).read()
def val(name):
    m = re.search(rf"^{name}=(0x[0-9a-fA-F]{{64}})\s*$", text, re.M)
    return m.group(1).lower() if m else None
u, d = val("UPDATER_PRIVATE_KEY"), val("PRIVATE_KEY")
if not u: sys.exit("no UPDATER_PRIVATE_KEY in contracts/.env - run ./scripts/new-testnet-wallet.sh --role updater")
if u == d: sys.exit("the updater key equals the deployer key - refusing")
PY

cd "$ROOT/tools"
ENV_FILE="$ENV_FILE" python -c '
import os, re, sys
m = re.search(r"^UPDATER_PRIVATE_KEY=(0x[0-9a-fA-F]{64})\s*$", open(os.environ["ENV_FILE"]).read(), re.M)
sys.stdout.write(m.group(1))
' | npx wrangler secret put UPDATER_KEY --config ../keeper/wrangler.toml
echo "Done. The keeper Worker can now sign; its next scheduled run publishes."
