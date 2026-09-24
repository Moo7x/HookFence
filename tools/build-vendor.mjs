// Rebuild app/vendor/viem.js from the pinned viem in this folder and print its
// sha256. `node build-vendor.mjs --check` rebuilds in memory and fails if the
// committed file differs, so the vendored bundle can be audited against source.
//
// Why vendor at all: the page used to import viem from esm.sh at runtime. Any
// script in the page can read what the page can read - including, in test-signer
// mode, the per-run signing token. Serving our own pinned bundle, under a CSP
// of script-src 'self', leaves no third-party code in the page.
import { build } from 'esbuild';
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const out = fileURLToPath(new URL('../app/vendor/viem.js', import.meta.url));
const pkg = JSON.parse(readFileSync(new URL('./node_modules/viem/package.json', import.meta.url)));

const result = await build({
  entryPoints: [fileURLToPath(new URL('./viem-entry.mjs', import.meta.url))],
  bundle: true, format: 'esm', platform: 'browser', target: 'es2020',
  minify: true, legalComments: 'inline', write: false,
  banner: { js: `// viem ${pkg.version}, bundled by tools/build-vendor.mjs. Do not edit; rebuild.` },
});
const code = result.outputFiles[0].contents;
const sha = createHash('sha256').update(code).digest('hex');

if (process.argv.includes('--check')) {
  const committed = readFileSync(out);
  const same = createHash('sha256').update(committed).digest('hex') === sha;
  console.log(same ? `app/vendor/viem.js matches a fresh build (sha256 ${sha})` : 'app/vendor/viem.js DIFFERS from a fresh build');
  process.exitCode = same ? 0 : 1;
} else {
  writeFileSync(out, code);
  console.log(`wrote app/vendor/viem.js  ${code.length} bytes  viem ${pkg.version}  sha256 ${sha}`);
}
