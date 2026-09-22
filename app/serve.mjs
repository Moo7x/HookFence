// Minimal static server for the Jayo demo.
//
// Serves the repository root so the page can read
// contracts/reports/jayo-local.json alongside app/index.html.
//
//   node app/serve.mjs   ->  http://127.0.0.1:5173
import { createServer } from "http";
import { readFile } from "fs/promises";
import { extname, join, normalize } from "path";
import { fileURLToPath } from "url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".json": "application/json",
  ".css": "text/css",
  ".svg": "image/svg+xml",
};

createServer(async (req, res) => {
  let p = decodeURIComponent(req.url.split("?")[0]);
  if (p === "/") p = "/app/index.html";

  // Keep requests inside ROOT.
  const safe = normalize(p).replace(/^([/\\]|\.\.)+/, "");
  const file = join(ROOT, safe);

  try {
    const data = await readFile(file);
    res.writeHead(200, {
      "content-type": TYPES[extname(file)] || "application/octet-stream",
      "cache-control": "no-store",
    });
    res.end(data);
  } catch {
    res.writeHead(404, { "content-type": "text/plain" });
    res.end("not found: " + safe);
  }
}).listen(5173, () => {
  console.log("Jayo demo running at http://127.0.0.1:5173");
  console.log("serving from " + ROOT);
});
