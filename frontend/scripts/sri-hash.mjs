#!/usr/bin/env node
/**
 * Generate SRI hash for a URL or file.
 * Usage:
 *   node frontend/scripts/sri-hash.mjs https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js
 *   node frontend/scripts/sri-hash.mjs --file ./public/script.js
 *   node frontend/scripts/sri-hash.mjs --text "console.log('hi')"
 *   curl -s https://cdn.example.com/lib.js | node frontend/scripts/sri-hash.mjs --stdin
 */
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

const algo = process.env.SRI_ALGO || "sha384";

function toIntegrity(buffer, algorithm = algo) {
  const hash = createHash(algorithm.replace("-", "")).update(buffer).digest("base64");
  return `${algorithm}-${hash}`;
}

async function fetchBuffer(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Fetch failed ${res.status} ${res.statusText} for ${url}`);
  const ab = await res.arrayBuffer();
  return Buffer.from(ab);
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length === 0 || args.includes("--help") || args.includes("-h")) {
    console.log(`
Usage:
  node frontend/scripts/sri-hash.mjs <url>
  node frontend/scripts/sri-hash.mjs --file <path>
  node frontend/scripts/sri-hash.mjs --text "<string>"
  node frontend/scripts/sri-hash.mjs --stdin < file.js

Options:
  SRI_ALGO=sha384|sha512|sha256  default sha384
Examples:
  node frontend/scripts/sri-hash.mjs https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js
  node frontend/scripts/sri-hash.mjs --file ./public/service-worker.js
    `);
    process.exit(0);
  }

  let buffer;
  if (args[0] === "--file") {
    buffer = await readFile(args[1]);
  } else if (args[0] === "--text") {
    buffer = Buffer.from(args[1], "utf8");
  } else if (args[0] === "--stdin") {
    const chunks = [];
    for await (const c of process.stdin) chunks.push(c);
    buffer = Buffer.concat(chunks);
  } else {
    const url = args[0];
    if (!/^https?:\/\//.test(url)) {
      console.error(`First arg must be https:// URL or --file/--text/--stdin`);
      process.exit(1);
    }
    buffer = await fetchBuffer(url);
  }

  const integrity = toIntegrity(buffer, algo);
  console.log(integrity);
  console.log(`\n// Add to frontend/src/lib/sri.ts SRI_MANIFEST:`);
  if (args[0] && /^https?:\/\//.test(args[0])) {
    console.log(`"${args[0]}": "${integrity}",`);
  }
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
