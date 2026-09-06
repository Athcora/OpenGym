import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the OpenGym entry screen", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);
  const html = await response.text();
  assert.match(html, /<title>OpenGym Volleyball Waitlist<\/title>/i);
  assert.match(html, /Choose your facility/);
  assert.match(html, /Facility name or code/);
  assert.match(html, /open-gym-app-icon\.png/);
  assert.doesNotMatch(html, /Your site is taking shape|Building your site/);
});

test("keeps metadata and the interactive app wired to the root route", async () => {
  const [page, layout] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
  ]);
  assert.match(page, /import WaitlistApp from "\.\/WaitlistApp"/);
  assert.match(page, /<AppErrorBoundary><WaitlistApp \/><\/AppErrorBoundary>/);
  assert.match(page, /serviceWorker\.register\("\/sw\.js"\)/);
  assert.match(layout, /export const metadata:\s*Metadata/);
  assert.match(layout, /title:\s*"OpenGym Volleyball Waitlist"/);
  assert.match(layout, /manifest:\s*"\/manifest\.webmanifest"/);
});
