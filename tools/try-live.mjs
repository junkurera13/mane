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
const anchors = {};
args.forEach((a, i) => {
  if (a === "--style") { const [id, ...rest] = args[i + 1].split("="); styles.push({ id, prompt: rest.join("=") }); }
  if (a === "--anchor") { const [id, file] = args[i + 1].split("="); anchors[id] = file; }
});

const video = resolve(opt("video", "face.mjpeg"));
const out = resolve(opt("out", "shots"));
const seconds = Number(opt("seconds", "6"));
const engines = opt("engines", "eden,lucy").split(",");
const edenEndpoint = opt("eden-endpoint", "vast/eden-live-5b-video");
const record = args.includes("--record");
// --app-flow: do what the app does. Each --style is "id=look"; anchors are made with Nano Banana
// from the live camera frame; the first cut waits for its anchor, later cuts use cached ones.
const appFlow = args.includes("--app-flow");
const edenPrompt = (look) => `A photorealistic live video of the same person with ${look}. Same face, identity, expression, skin, clothing, lighting and background as the camera.`;
const livePrompt = (look) => `Change the person's hair to ${look}. Keep the same face, identity, expression, clothing and background.`;
const anchorPrompt = (look) => `Edit only the hair: give this person ${look}. Keep exactly the same face, identity, expression, skin, lighting, clothing, background, camera angle and framing. Photorealistic photo.`;
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
const context = await browser.newContext({
  viewport: { width: 640, height: 640 },
  ...(record ? { recordVideo: { dir: out, size: { width: 640, height: 640 } } } : {}),
});
const page = await context.newPage();
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
await page.evaluate((c) => window.mane.config(c), { engines, expandPrompt: expand, eden: { endpoint: edenEndpoint, revealMs: 500 } });

console.log("open camera");
await page.evaluate(() => window.mane.open());
await page.waitForTimeout(1500);
await page.screenshot({ path: join(out, "00-real.png") });

const waitFor = async (pred, ms) => {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { if (await page.evaluate(pred)) return true; await page.waitForTimeout(200); }
  return false;
};

async function makeAnchor(look) {
  const frame = await page.evaluate(() => window.mane.frame(896, 0.85));
  const body = JSON.stringify({ prompt: anchorPrompt(look), image_urls: [frame], num_images: 1, output_format: "jpeg", aspect_ratio: "16:9" });
  const res = JSON.parse(execFileSync("curl", ["-sS", "-m", "90", "-X", "POST", "https://fal.run/fal-ai/nano-banana/edit",
    "-H", "Authorization: Key " + key, "-H", "Content-Type: application/json", "--data-binary", "@-"], { input: body }).toString());
  const img = execFileSync("curl", ["-sS", "-m", "60", res.images[0].url]);
  const src = "data:image/jpeg;base64," + img.toString("base64");
  return page.evaluate(async (src) => {
    const im = new Image(); im.src = src; await im.decode();
    const w = 640, h = Math.round(im.naturalHeight * w / im.naturalWidth);
    const c = document.createElement("canvas"); c.width = w; c.height = h;
    c.getContext("2d").drawImage(im, 0, 0, w, h);
    return c.toDataURL("image/jpeg", 0.7);
  }, src);
}

let n = 1;
if (appFlow) {
  const cache = {};
  for (const [i, s] of styles.entries()) {
    const look = s.prompt;
    console.log(`style ${s.id}: ${look}`);
    const t0 = Date.now();
    if (!cache[s.id]) {
      if (i === 0) await page.evaluate(() => window.mane.warm());
      cache[s.id] = await makeAnchor(look);
      console.log(`  anchor ${s.id}: ${Date.now() - t0} ms, ${cache[s.id].length} chars`);
      writeFileSync(join(out, `anchor-${s.id}.jpg`), Buffer.from(cache[s.id].split(",")[1], "base64"));
    }
    const t1 = Date.now();
    await page.evaluate(({ id, p }) => window.mane.apply(id, p), { id: s.id, p: { eden: edenPrompt(look), lucy: livePrompt(look), anchor: cache[s.id] } });
    const ok = await waitFor(() => window.mane.state().showingAI && !window.mane.state().busy, 100000);
    console.log(`  showing AI: ${ok} after ${Date.now() - t1} ms from apply (${Date.now() - t0} ms from tap)`);
    // Like the app: after the first cut, make the next ones' anchors while this one plays.
    if (i === 0) for (const nx of styles.slice(1)) {
      const ta = Date.now(); cache[nx.id] = await makeAnchor(nx.prompt);
      console.log(`  prefetched anchor ${nx.id}: ${Date.now() - ta} ms`);
      writeFileSync(join(out, `anchor-${nx.id}.jpg`), Buffer.from(cache[nx.id].split(",")[1], "base64"));
    }
    for (let k = 1; k <= 3; k++) {
      await page.waitForTimeout((seconds * 1000) / 3);
      await page.screenshot({ path: join(out, `${String(n).padStart(2, "0")}-${s.id}-${k}.png`) });
    }
    n++;
  }
}
for (const s of appFlow ? [] : styles) {
  console.log(`style ${s.id}: ${s.prompt}`);
  const t0 = Date.now();
  const anchor = anchors[s.id] ? "data:image/jpeg;base64," + readFileSync(anchors[s.id]).toString("base64") : undefined;
  await page.evaluate(({ id, prompt, anchor }) => window.mane.apply(id, anchor ? { eden: prompt, lucy: prompt, anchor } : prompt), { ...s, anchor });
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
await context.close();
await browser.close();
