#!/usr/bin/env bash
# Create a DEDICATED throwaway testnet wallet and store its key in contracts/.env.
#
#   ./scripts/new-testnet-wallet.sh                 the deployer (admin, feed keeper)
#   ./scripts/new-testnet-wallet.sh --role alice    demo user A
#   ./scripts/new-testnet-wallet.sh --role bob      demo user B
#
# Three separate keys on purpose. The deployer owns the contracts and writes the
# price feeds; it is never loaded by the interface's test signer. Alice and Bob
# are ordinary users: two independent wallets, so the public proof can show a
# basket handed from one to the other and the recipient withdrawing it.
#
# The key is written to contracts/.env only (git-ignored) and is never printed,
# never held in a shell variable, and never passed on a command line. Never paste
# it into a chat window, an issue, or a commit.
#
# REFUSES TO OVERWRITE. If contracts/.env already holds a key for that role, this
# exits without touching anything, because replacing a key that has been funded,
# or that owns a deployment, strands both.
#
# An earlier version parsed `cast wallet new`'s human-readable output. That output
# is split across stdout and stderr, so the capture missed half of it: the key was
# printed to the terminal and the script then failed without writing anything.
# This version asks cast for JSON and hands it straight to Python.
set -euo pipefail
export PATH="$PATH:$HOME/.foundry/bin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/contracts/.env"

ROLE="deployer"
if [ "${1:-}" = "--role" ]; then ROLE="${2:-}"; fi
case "$ROLE" in
  deployer) KEY_VAR=PRIVATE_KEY;       ADDR_VAR=DEPLOYER_ADDRESS ;;
  alice)    KEY_VAR=ALICE_PRIVATE_KEY; ADDR_VAR=ALICE_ADDRESS ;;
  bob)      KEY_VAR=BOB_PRIVATE_KEY;   ADDR_VAR=BOB_ADDRESS ;;
  *) echo "unknown role '$ROLE' (use deployer, alice or bob)"; exit 2 ;;
esac

if [ -f "$ENV_FILE" ] && grep -qE "^${KEY_VAR}=.+" "$ENV_FILE"; then
  echo "contracts/.env already holds $KEY_VAR. Nothing was changed."
  ADDR_LINE="$(grep -E "^${ADDR_VAR}=" "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  [ -n "$ADDR_LINE" ] && echo "  It controls: $ADDR_LINE"
  echo "To replace it on purpose, remove that line from contracts/.env yourself first."
  exit 1
fi

cast wallet new --json 2>&1 | ENV_FILE="$ENV_FILE" EXAMPLE="$ROOT/.env.example" \
  KEY_VAR="$KEY_VAR" ADDR_VAR="$ADDR_VAR" ROLE="$ROLE" python -c '
import json, os, sys, tempfile

raw = sys.stdin.read()
try:
    entry = json.loads(raw)["data"][0]
    key, addr = entry["private_key"], entry["address"]
except Exception:
    sys.exit("could not read a key from cast (output withheld on purpose)")
if not (key.startswith("0x") and len(key) == 66 and addr.startswith("0x") and len(addr) == 42):
    sys.exit("cast returned an unexpected key shape (output withheld on purpose)")

env_file, example = os.environ["ENV_FILE"], os.environ["EXAMPLE"]
kv, av = os.environ["KEY_VAR"], os.environ["ADDR_VAR"]
base = open(env_file).read() if os.path.exists(env_file) else (open(example).read() if os.path.exists(example) else "")
lines = [l for l in base.splitlines() if not l.startswith((kv + "=", av + "="))]
lines += [kv + "=" + key, av + "=" + addr]

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(env_file), prefix=".env.")
with os.fdopen(fd, "w") as f:
    f.write("\n".join(lines) + "\n")
try:
    os.chmod(tmp, 0o600)
except OSError:
    pass
os.replace(tmp, env_file)

print("Dedicated testnet wallet created (" + os.environ["ROLE"] + ").")
print("  Address : " + addr)
print("  Key     : in contracts/.env as " + kv + " (git-ignored). Not printed; do not paste it anywhere.")
'
