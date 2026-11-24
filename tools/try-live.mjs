// Drives web/mirror.html in headless Chromium with a fake camera, so the live AI
// haircut pipeline can be tested without a Mac.
//
//   FAL_KEY=... node tools/try-live.mjs --video face.mjpeg --out shots \
//       --style "buzz=Give the person a buzz cut" --style "blonde=..." --seconds 6
//
// Needs Playwright with Chromium (`npm i -g playwright` + `npx playwright install chromium`).
// Each run opens one live session: about 2¢ per second on fal.
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const { chromium } = createRequire(import.meta.url)("playwright");
const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, dflt) => { const i = args.indexOf("--" + name); return i >= 0 ? args[i + 1] : dflt; };
const styles = [];
args.forEach((a, i) => { if (a === "--style") { const [id, ...rest] = args[i + 1].split("="); styles.push({ id, prompt: rest.join("=") }); } });

const video = resolve(opt("video", "face.mjpeg"));
const out = resolve(opt("out", "shots"));
const seconds = Number(opt("seconds", "6"));
const engines = opt("engines", "eden,lucy").split(",");
const expand = opt("expand", "false") === "true";
const extraArgs = (opt("chrome-args", "") || "").split(" ").filter(Boolean);
const key = process.env.FAL_KEY;
if (!key) { console.error("Set FAL_KEY"); process.exit(1); }
mkdirSync(out, { recursive: true });

function mintToken() {
  const alias = "lucy-2-6";
  const body = JSON.stringify({ allowed_apps: [alias], token_expiration: 120 });
  const res = execFileSync("curl", ["-sS", "-m", "20", "-X", "POST", "https://rest.fal.ai/tokens/",
    "-H", "Authorization: Key " + key, "-H", "Content-Type: application/json", "-d", body]).toString();
  const t = JSON.parse(res);
  if (typeof t !== "string") throw new Error("token: " + res.slice(0, 200));
  return t;
}

const html = readFileSync(join(here, "..", "web", "mirror.html"), "utf8");
const falBundle = readFileSync(join(here, "..", "web", "vendor", "fal-realtime.js"), "utf8");
const proxy = process.env.HTTPS_PROXY ? { server: process.env.HTTPS_PROXY } : undefined;
const browser = await chromium.launch({
  proxy,
  args: [
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    "--use-file-for-fake-video-capture=" + video,
    "--autoplay-policy=no-user-gesture-required",
    ...extraArgs,
  ],
});
const page = await browser.newPage({ viewport: { width: 640, height: 640 } });
const events = [];
await page.exposeBinding("__maneNative", (_src, msg) => {
  events.push(msg);
  if (msg.type === "needToken") {
    try { const t = mintToken(); page.evaluate((t) => window.mane.setToken(t), t).catch(() => {}); }
    catch (e) { console.error(String(e)); }
  } else if (msg.type !== "signal" || msg.kind !== "icecandidate") {
    console.log("  ·", JSON.stringify(msg).slice(0, 600));
  }
});
await page.addInitScript(({ key }) => {
  window.webkit = { messageHandlers: { mane: { postMessage: (m) => window.__maneNative(m) } } };
  // In the app, fal HTTP calls go through Swift, which adds the key. Here the test adds it.
  window.__maneTestFetch = (url, init = {}) => {
    const headers = new Headers(init.headers || {});
    headers.set("Authorization", "Key " + key);
    return fetch(url, { ...init, headers });
  };
}, { key });
await page.addInitScript({ content: falBundle });
page.on("console", (m) => console.log("  console:", m.text()));
await page.route("https://mane.test/**", (r) => r.fulfill({ contentType: "text/html", body: html }));
await page.goto("https://mane.test/");
await page.evaluate((c) => window.mane.config(c), { engines, expandPrompt: expand });

console.log("open camera");
await page.evaluate(() => window.mane.open());
await page.waitForTimeout(1500);
await page.screenshot({ path: join(out, "00-real.png") });

const waitFor = async (pred, ms) => {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { if (await page.evaluate(pred)) return true; await page.waitForTimeout(200); }
  return false;
};

let n = 1;
for (const s of styles) {
  console.log(`style ${s.id}: ${s.prompt}`);
  const t0 = Date.now();
  await page.evaluate(({ id, prompt }) => window.mane.apply(id, prompt), s);
  const ok = await waitFor(() => window.mane.state().showingAI && !window.mane.state().busy, 60000);
  console.log(`  showing AI: ${ok} after ${Date.now() - t0} ms`);
  for (let k = 1; k <= 3; k++) {
    await page.waitForTimeout((seconds * 1000) / 3);
    await page.screenshot({ path: join(out, `${String(n).padStart(2, "0")}-${s.id}-${k}.png`) });
  }
  n++;
}

console.log("back to real hair, close");
await page.evaluate(() => window.mane.apply(null, null));
await page.waitForTimeout(800);
await page.screenshot({ path: join(out, `${String(n).padStart(2, "0")}-real-again.png`) });
await page.evaluate(() => window.mane.close());
writeFileSync(join(out, "events.json"), JSON.stringify(events, null, 1));
await browser.close();
