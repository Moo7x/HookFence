// Rebuild the vendored viem bundles from the pinned viem in this folder and print
// their sha256. `node build-vendor.mjs --check` rebuilds in memory and fails if a
// committed file differs, so each bundle can be audited against source.
//
//   app/vendor/viem.js         local demo + local server (includes account code,
//                              used only with anvil's published keys)
//   app/vendor/viem-hosted.js  the public site: no account or key handling at all;
//                              the visitor's wallet signs. build-site.mjs ships it
//                              as /app/vendor/viem.js.
//
// Why vendor at all: the page used to import viem from esm.sh at runtime. Any
// script in a page can read what the page can read. Serving our own pinned
// bundle, under a CSP of script-src 'self', leaves no third-party code in it.
import { build } from 'esbuild';
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const pkg = JSON.parse(readFileSync(new URL('./node_modules/viem/package.json', import.meta.url)));
const TARGETS = [
  { entry: './viem-entry.mjs', out: '../app/vendor/viem.js' },
  { entry: './viem-entry-hosted.mjs', out: '../app/vendor/viem-hosted.js' },
];
const check = process.argv.includes('--check');
let bad = 0;

for (const t of TARGETS) {
  const result = await build({
    entryPoints: [fileURLToPath(new URL(t.entry, import.meta.url))],
    bundle: true, format: 'esm', platform: 'browser', target: 'es2020',
    minify: true, legalComments: 'inline', write: false,
    banner: { js: `// viem ${pkg.version}, bundled by tools/build-vendor.mjs from ${t.entry.slice(2)}. Do not edit; rebuild.` },
  });
  const code = result.outputFiles[0].contents;
  const sha = createHash('sha256').update(code).digest('hex');
  const outPath = fileURLToPath(new URL(t.out, import.meta.url));
  const name = t.out.replace('../', '');
  if (check) {
    let same = false;
    try { same = createHash('sha256').update(readFileSync(outPath)).digest('hex') === sha; } catch {}
    console.log(same ? `${name} matches a fresh build (sha256 ${sha})` : `${name} DIFFERS from a fresh build`);
    if (!same) bad++;
  } else {
    writeFileSync(outPath, code);
    console.log(`wrote ${name}  ${code.length} bytes  viem ${pkg.version}  sha256 ${sha}`);
  }
}
process.exitCode = bad ? 1 : 0;
