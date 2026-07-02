// SPDX-License-Identifier: GPL-3.0-or-later

import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(process.argv[2] ?? "zig-out/web");
const port = Number(process.argv[3] ?? process.env.PORT ?? 4173);
const host = process.env.HOST ?? "127.0.0.1";

const mimeTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".mjs", "text/javascript; charset=utf-8"],
  [".wasm", "application/wasm"],
  [".css", "text/css; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".map", "application/json; charset=utf-8"],
  [".txt", "text/plain; charset=utf-8"],
  [".md", "text/markdown; charset=utf-8"],
]);

function safePath(pathname) {
  const decoded = decodeURIComponent(pathname);
  const relative = normalize(decoded === "/" ? "/zigfall.html" : decoded).replace(/^([/\\])+/, "");
  const absolute = resolve(join(root, relative));
  if (absolute !== root && !absolute.startsWith(root + sep)) return null;
  return absolute;
}

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
    if (url.pathname === "/favicon.ico") {
      response.writeHead(204).end();
      return;
    }

    const filePath = safePath(url.pathname);
    if (!filePath) {
      response.writeHead(403).end("forbidden");
      return;
    }

    const info = await stat(filePath);
    if (!info.isFile()) {
      response.writeHead(404).end("not found");
      return;
    }

    response.writeHead(200, {
      "content-type": mimeTypes.get(extname(filePath)) ?? "application/octet-stream",
      "cache-control": "no-store",
      "cross-origin-opener-policy": "same-origin",
      "cross-origin-embedder-policy": "require-corp",
    });
    createReadStream(filePath).pipe(response);
  } catch (err) {
    if (err && err.code === "ENOENT") {
      response.writeHead(404).end("not found");
    } else {
      console.error(err);
      response.writeHead(500).end("internal error");
    }
  }
});

server.listen(port, host, () => {
  console.log(`Serving ${root} at http://${host}:${port}/zigfall.html`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
  });
}

export const __filename = fileURLToPath(import.meta.url);
