// SPDX-License-Identifier: GPL-3.0-or-later

import { expect, test } from "@playwright/test";
import { access } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const fakeTransportPath = fileURLToPath(new URL("./fake_transport.js", import.meta.url));

async function requireWebArtifact() {
  await access("zig-out/web/zigfall.html");
  await access("zig-out/web/zigfall.js");
  await access("zig-out/web/zigfall.wasm");
}

test.beforeAll(requireWebArtifact);

async function installFakeTransport(page) {
  await page.addInitScript({ path: fakeTransportPath });
}

async function openGame(page, url = "/zigfall.html") {
  await page.goto(url);
  await waitForWasm(page);
}

async function waitForWasm(page) {
  await page.waitForFunction(() => globalThis.Module?.calledRun === true, null, { timeout: 15_000 });
  await expect(page.locator("#status")).toHaveText(/Running|Ready|All downloads complete/);
}

async function pressGameKey(page, key) {
  await page.locator("#canvas").click({ position: { x: 12, y: 12 } });
  await page.keyboard.down(key);
  await page.waitForTimeout(80);
  await page.keyboard.up(key);
}

async function startOnlineHost(page) {
  await pressGameKey(page, "Digit3");
  await expect.poll(async () => page.evaluate(() => globalThis.ZigfallTransport.debugSnapshot().roomId), {
    message: "host should connect a fake room after pressing the online hotkey",
    timeout: 10_000,
  }).toMatch(/^[A-Za-z0-9._~-]{1,128}$/);
  return page.evaluate(() => globalThis.ZigfallTransport.debugSnapshot().roomId);
}

async function transportSnapshot(page) {
  return page.evaluate(() => globalThis.ZigfallTransport.debugSnapshot());
}

async function waitForFakeConnected(page) {
  await expect.poll(async () => (await transportSnapshot(page)).statusName, {
    timeout: 10_000,
  }).toBe("connected");
}

test("loads the built WebAssembly artifact and exposes transport diagnostics", async ({ page }) => {
  await openGame(page);

  const snapshot = await transportSnapshot(page);
  const canvas = await page.locator("#canvas").evaluate((element) => ({
    width: element.width,
    height: element.height,
    clientWidth: element.clientWidth,
    clientHeight: element.clientHeight,
  }));

  expect(snapshot.statusName).toBe("disconnected");
  expect(snapshot.incoming.depth).toBe(0);
  expect(snapshot.send.pending).toBe(0);
  expect(canvas.width).toBe(1100);
  expect(canvas.height).toBe(720);
});

test("starts an online host through the browser UI with a deterministic fake transport", async ({ page }) => {
  await installFakeTransport(page);
  await openGame(page);

  const roomId = await startOnlineHost(page);
  const snapshot = await transportSnapshot(page);

  expect(snapshot.fake).toBe(true);
  expect(snapshot.connects).toHaveLength(1);
  expect(snapshot.connects[0].roomId).toBe(roomId);
  expect(snapshot.statusName).toBe("connecting");
});

test("two browser pages exchange Zigfall online packets through the WASM bridge", async ({ context }) => {
  const host = await context.newPage();
  const joiner = await context.newPage();
  await installFakeTransport(host);
  await installFakeTransport(joiner);

  try {
    await openGame(host);
    const roomId = await startOnlineHost(host);
    await openGame(joiner, `/zigfall.html?join=${encodeURIComponent(roomId)}`);

    await waitForFakeConnected(host);
    await waitForFakeConnected(joiner);

    await expect.poll(async () => (await transportSnapshot(host)).send.attempts, {
      message: "host should send setup/profile/input packets through the fake browser transport",
      timeout: 10_000,
    }).toBeGreaterThan(0);
    await expect.poll(async () => (await transportSnapshot(joiner)).send.attempts, {
      message: "joiner should send ack/profile/input packets through the fake browser transport",
      timeout: 10_000,
    }).toBeGreaterThan(0);
    await expect.poll(async () => (await transportSnapshot(host)).receivedPackets.length, {
      message: "host should receive packets from the joiner",
      timeout: 10_000,
    }).toBeGreaterThan(0);
    await expect.poll(async () => (await transportSnapshot(joiner)).receivedPackets.length, {
      message: "joiner should receive packets from the host",
      timeout: 10_000,
    }).toBeGreaterThan(0);

    const hostSnapshot = await transportSnapshot(host);
    const joinerSnapshot = await transportSnapshot(joiner);
    expect(hostSnapshot.peers.count).toBe(1);
    expect(joinerSnapshot.peers.count).toBe(1);
    expect(hostSnapshot.send.sentPackets.some((packet) => packet.length > 0)).toBe(true);
    expect(joinerSnapshot.send.sentPackets.some((packet) => packet.length > 0)).toBe(true);
  } finally {
    await host.close();
    await joiner.close();
  }
});
