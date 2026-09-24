"""Scan EVERY blob in the git history - all branches, all tags, every version of
every file ever committed - for secrets, before a repository is made public.

    python scripts/scan-git-history.py

Looks for:
  - the real keys in contracts/.env, by exact value (the ones that matter most);
  - any `*PRIVATE_KEY=0x<64 hex>` assignment;
  - 64-hex values next to words like key/secret/private/mnemonic (reported with
    context, so anvil's published development keys can be told apart);
  - common credential formats (GitHub, AWS, Google, Slack, Stripe, OpenAI and
    Anthropic keys, PEM private keys, JWTs, RPC URLs with embedded API keys);
  - sensitive file names ever committed (.env, *.pem, *.key, keystores);
and prints the author and committer identities that become public with the repo.

Exits 1 if a real key or a credential is found; anvil's published keys are
reported but do not fail the scan.
"""
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ANVIL = {
    "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
}

real_keys = set()
env = REPO / "contracts" / ".env"
if env.exists():
    for m in re.finditer(r"^[A-Z_]*PRIVATE_KEY=0x([0-9a-fA-F]{64})\s*$", env.read_text(), re.M):
        real_keys.add(m.group(1).lower())

CREDENTIALS = {
    "GitHub token": re.compile(rb"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|github_pat_[A-Za-z0-9_]{60,}"),
    "AWS access key": re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    "Google API key": re.compile(rb"\bAIza[0-9A-Za-z\-_]{35}\b"),
    "Slack token": re.compile(rb"\bxox[baprs]-[0-9A-Za-z-]{10,}"),
    "Stripe live key": re.compile(rb"\b[rs]k_live_[0-9A-Za-z]{20,}"),
    "OpenAI/Anthropic key": re.compile(rb"\bsk-(ant-)?[A-Za-z0-9_\-]{32,}"),
    "PEM private key": re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "JWT": re.compile(rb"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
    "RPC URL with API key": re.compile(rb"(alchemy\.com/v2/|infura\.io/v3/|quiknode\.pro/)[A-Za-z0-9_-]{16,}"),
    "Etherscan-style API key": re.compile(rb"(?i)(etherscan|blockscout)[_ -]?api[_ -]?key\s*[=:]\s*[A-Z0-9]{30,}"),
}
KEY_ASSIGN = re.compile(rb"PRIVATE_KEY\s*=\s*0x([0-9a-fA-F]{64})\b")
HEX64 = re.compile(rb"(?<![0-9a-fA-F])(?:0x)?([0-9a-fA-F]{64})(?![0-9a-fA-F])")
KEYWORDY = re.compile(rb"(?i)(private|secret|mnemonic|seed|priv_?key|signer|--private-key|PK=)")
SENSITIVE_NAMES = re.compile(r"(^|/)(\.env(\..*)?|.*\.pem|.*\.key|keystore/.*|.*\.keystore|id_rsa.*)$")


def git(*args, input=None):
    return subprocess.run(["git", *args], cwd=REPO, input=input, capture_output=True, check=True).stdout


objects = git("rev-list", "--all", "--objects").decode().splitlines()
blobs = {}
for line in objects:
    parts = line.split(" ", 1)
    if len(parts) == 2:
        blobs.setdefault(parts[0], set()).add(parts[1])
types = git("cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)",
            input="\n".join(blobs).encode()).decode().splitlines()
blob_ids = [t.split()[0] for t in types if t.split()[1] == "blob"]
data = git("cat-file", "--batch", input="\n".join(blob_ids).encode())

findings, anvil_seen, contextual = [], set(), []
i = 0
while i < len(data):
    nl = data.index(b"\n", i)
    oid, _, size = data[i:nl].decode().split()
    size = int(size)
    body = data[nl + 1: nl + 1 + size]
    i = nl + 1 + size + 1
    paths = ", ".join(sorted(blobs.get(oid, {"?"})))
    low = body.lower()

    for k in real_keys:
        if k.encode() in low:
            findings.append(f"REAL KEY from contracts/.env in {paths} (blob {oid[:10]})")
    for m in KEY_ASSIGN.finditer(body):
        v = m.group(1).decode().lower()
        (anvil_seen.add(paths) if v in ANVIL else findings.append(f"PRIVATE_KEY assignment with a non-anvil value in {paths}"))
    for name, rx in CREDENTIALS.items():
        if rx.search(body):
            findings.append(f"{name} pattern in {paths} (blob {oid[:10]})")
    for m in HEX64.finditer(body):
        v = m.group(1).decode().lower()
        if v in ANVIL:
            anvil_seen.add(paths)
            continue
        if v in real_keys:
            continue
        ctx = body[max(0, m.start() - 60): m.start()]
        if KEYWORDY.search(ctx):
            contextual.append(f"{paths}: ...{ctx[-40:].decode(errors='replace')!r} 0x{v[:8]}...")

names = git("log", "--all", "--format=", "--name-only").decode().splitlines()
bad_names = sorted({n for n in names if n and SENSITIVE_NAMES.search(n) and not n.endswith(".env.example")})

idents = sorted(set(git("log", "--all", "--format=%an <%ae>%n%cn <%ce>").decode().splitlines()))
commits = int(git("rev-list", "--all", "--count").decode().strip())

print(f"scanned {len(blob_ids)} blobs across {commits} commits on all refs")
print(f"real keys checked by exact value: {len(real_keys)}")
print(f"\nsensitive file names ever committed: {bad_names or 'none'}")
print(f"\nanvil's published development keys appear in (expected, public, hold nothing):")
for p in sorted(anvil_seen):
    print(f"   {p}")
print(f"\n64-hex values next to key-like words, not anvil and not a real key ({len(contextual)}):")
for c in contextual[:40]:
    print(f"   {c}")
print(f"\nidentities that become public with the history:")
for ident in idents:
    print(f"   {ident}")
print(f"\nFINDINGS: {len(findings)}")
for f in findings:
    print(f"   {f}")
sys.exit(1 if findings else 0)
