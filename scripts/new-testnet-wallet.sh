#!/usr/bin/env bash
# Create a DEDICATED throwaway testnet wallet and store its key in contracts/.env.
#
#   ./scripts/new-testnet-wallet.sh
#
# The key is written to contracts/.env only (git-ignored) and is never printed,
# never held in a shell variable, and never passed on a command line. Never paste
# it into a chat window, an issue, or a commit.
#
# REFUSES TO OVERWRITE. If contracts/.env already holds a PRIVATE_KEY, this exits
# without touching anything, because replacing a key that has been funded, or that
# owns a deployment, strands both. To start again deliberately, move the old file
# aside yourself first.
#
# An earlier version parsed `cast wallet new`'s human-readable output. That output
# is split across stdout and stderr, so the capture missed half of it: the key was
# printed to the terminal and the script then failed without writing anything.
# This version asks cast for JSON and hands it straight to Python.
set -euo pipefail
export PATH="$PATH:$HOME/.foundry/bin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/contracts/.env"

if [ -f "$ENV_FILE" ] && grep -qE '^PRIVATE_KEY=.+' "$ENV_FILE"; then
  echo "contracts/.env already holds a PRIVATE_KEY. Nothing was changed."
  ADDR_LINE="$(grep -E '^DEPLOYER_ADDRESS=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  [ -n "$ADDR_LINE" ] && echo "  It controls: $ADDR_LINE"
  echo "To replace it on purpose:  mv contracts/.env contracts/.env.old  and run this again."
  exit 1
fi

cast wallet new --json 2>&1 | ENV_FILE="$ENV_FILE" EXAMPLE="$ROOT/.env.example" python -c '
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
base = open(env_file).read() if os.path.exists(env_file) else (open(example).read() if os.path.exists(example) else "")
lines = [l for l in base.splitlines() if not l.startswith(("PRIVATE_KEY=", "DEPLOYER_ADDRESS="))]
lines += ["PRIVATE_KEY=" + key, "DEPLOYER_ADDRESS=" + addr]

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(env_file), prefix=".env.")
with os.fdopen(fd, "w") as f:
    f.write("\n".join(lines) + "\n")
try:
    os.chmod(tmp, 0o600)
except OSError:
    pass
os.replace(tmp, env_file)

print("Dedicated testnet wallet created.")
print("  Address : " + addr)
print("  Key     : in contracts/.env (git-ignored). Not printed; do not paste it anywhere.")
print()
print("Check its balance with:")
print("  cast balance " + addr + " --rpc-url https://rpc.testnet.chain.robinhood.com --ether")
'
