/**
 * Capture every locale page in light and dark, at desktop and mobile size.
 *
 *   node website/scripts/screenshots.mjs
 *   node website/scripts/screenshots.mjs --url https://screenclipai.com
 *   node website/scripts/screenshots.mjs --url http://127.0.0.1:4173
 *
 * With no --url, this builds the site and serves it. Screenshots are written to
 * website/screenshots/ (gitignored), with an HTML contact sheet at index.html.
 */
import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const REPO = path.resolve(ROOT, "..");
const OUT = path.join(ROOT, "screenshots");

const LOCALES = [
  { id: "en", path: "" },
  { id: "zh-hans", path: "zh-hans" },
  { id: "es", path: "es" },
  { id: "ja", path: "ja" },
  { id: "pt-br", path: "pt-br" },
  { id: "de", path: "de" },
  { id: "fr", path: "fr" },
  { id: "ko", path: "ko" },
  { id: "ru", path: "ru" },
  { id: "zh-hant", path: "zh-hant" },
];
const PAGES = [
  { id: "home", slug: "" },
  { id: "ios", slug: "ios" },
  { id: "privacy", slug: "privacy" },
  { id: "support", slug: "support" },
];
const THEMES = ["light", "dark"];
const VIEWPORTS = [
  { id: "desktop", width: 1440, height: 900 },
  { id: "mobile", width: 390, height: 844 },
];

function parseArgs(argv) {
  let url = "";
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--url") {
      url = argv[i + 1] || "";
      i += 1;
    } else if (arg.startsWith("--url=")) {
      url = arg.slice("--url=".length);
    } else if (arg === "--help" || arg === "-h") {
      console.log("Usage: node website/scripts/screenshots.mjs [--url BASE]");
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return { url };
}

function pageUrl(origin, locale, page) {
  const prefix = locale.path ? `/${locale.path}` : "";
  const tail = page.slug ? `/${page.slug}` : "";
  return new URL(`${prefix}${tail}` || "/", origin).href;
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function waitFor(url) {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const response = await fetch(url);
      if (response.ok) return;
    } catch {
      /* The preview server is still starting. */
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`Preview did not answer at ${url}`);
}

function startPreview(port) {
  const child = spawn("python3", ["website/build.py", "--preview", String(port)], {
    cwd: REPO,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let log = "";
  const collect = (chunk) => {
    log += chunk.toString();
    if (log.length > 8000) log = log.slice(-8000);
  };
  child.stdout.on("data", collect);
  child.stderr.on("data", collect);
  return {
    child,
    log: () => log,
    stop() {
      if (!child.killed) child.kill("SIGTERM");
    },
  };
}

function contactSheet(shots, origin) {
  const cards = shots.map((shot) => {
    const src = `${shot.locale}/${shot.file}`;
    return `<a class="card" href="${src}"><img src="${src}" alt="${shot.locale} ${shot.theme} ${shot.viewport} ${shot.page}"><span>${shot.locale} · ${shot.theme} · ${shot.viewport} · ${shot.page}</span></a>`;
  });
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ScreenClip website screenshots</title>
  <style>
    :root { color-scheme: light dark; }
    body { margin: 0; font: 15px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f6f3ec; color: #241f1a; }
    @media (prefers-color-scheme: dark) {
      body { background: #161411; color: #f4efe6; }
    }
    header, main { width: min(1400px, calc(100% - 2rem)); margin: 0 auto; }
    header { padding: 1.5rem 0 0.5rem; }
    h1 { font-size: 1.6rem; margin: 0 0 0.4rem; }
    p { margin: 0; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 0.8rem; padding: 1rem 0 2rem; }
    .card { color: inherit; text-decoration: none; border: 1px solid #e3dbd0; border-radius: 12px; overflow: hidden; background: #fffdf8; }
    @media (prefers-color-scheme: dark) {
      .card { border-color: #3d362f; background: #221e1a; }
    }
    .card img { display: block; width: 100%; height: 280px; object-fit: cover; object-position: top; background: #efe8dc; }
    .card span { display: block; padding: 0.55rem 0.7rem 0.7rem; font-size: 0.85rem; }
  </style>
</head>
<body>
  <header>
    <h1>ScreenClip website screenshots</h1>
    <p>${shots.length} full pages from ${origin}. Each frame shows the top of the page. Open a card for the full capture.</p>
  </header>
  <main class="grid">
    ${cards.join("\n    ")}
  </main>
</body>
</html>
`;
}

async function capture(origin) {
  const browser = await chromium.launch({
    headless: true,
    ...(process.env.SCREENCLIP_CHROMIUM_PATH ? { executablePath: process.env.SCREENCLIP_CHROMIUM_PATH } : {}),
  });
  const shots = [];
  try {
    for (const locale of LOCALES) {
      const dir = path.join(OUT, locale.id);
      await mkdir(dir, { recursive: true });
      for (const theme of THEMES) {
        for (const viewport of VIEWPORTS) {
          const context = await browser.newContext({
            viewport: { width: viewport.width, height: viewport.height },
            deviceScaleFactor: 1,
            colorScheme: theme,
            reducedMotion: "reduce",
          });
          await context.addCookies([{
            name: "screenclip_lang",
            value: locale.path || "en",
            url: origin,
          }]);
          const page = await context.newPage();
          for (const item of PAGES) {
            const target = pageUrl(origin, locale, item);
            const response = await page.goto(target, { waitUntil: "networkidle" });
            if (!response || response.status() >= 400) {
              throw new Error(`${target} returned ${response ? response.status() : "no response"}`);
            }
            // Full-page screenshots do not scroll to trigger lazy-loaded images.
            await page.locator("img").evaluateAll((images) => Promise.all(images.map((img) => {
              img.loading = "eager";
              return img.decode();
            })));
            const file = `${theme}-${viewport.id}-${item.id}.png`;
            await page.screenshot({ path: path.join(dir, file), fullPage: true });
            shots.push({ locale: locale.id, theme, viewport: viewport.id, page: item.id, file });
            console.log(`${locale.id}/${file}`);
          }
          await context.close();
        }
      }
    }
  } finally {
    await browser.close();
  }
  await writeFile(path.join(OUT, "index.html"), contactSheet(shots, origin));
  console.log(`Wrote ${shots.length} screenshots and ${path.join(OUT, "index.html")}`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  let origin = args.url ? new URL(args.url).origin : "";
  let preview = null;
  if (!origin) {
    const port = await freePort();
    origin = `http://127.0.0.1:${port}`;
    preview = startPreview(port);
    try {
      await waitFor(`${origin}/`);
    } catch (error) {
      preview.stop();
      throw new Error(`${error.message}\n${preview.log()}`);
    }
  }
  try {
    await capture(origin);
  } finally {
    if (preview) preview.stop();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
