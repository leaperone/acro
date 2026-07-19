import assert from "node:assert/strict";
import test from "node:test";
import { BrowserManager } from "./browser.ts";

test("browser capture coalesces concurrent starts and rechecks before stopping", async () => {
  const manager = new BrowserManager();
  let resolveStart!: () => void;
  const started = new Promise<void>((resolve) => {
    resolveStart = resolve;
  });
  let starts = 0;
  let stops = 0;
  const surface = {
    id: "browser",
    handle: 1,
    page: {},
    cdp: {
      send(method: string) {
        if (method === "Page.startScreencast") {
          starts += 1;
          return started;
        }
        if (method === "Page.stopScreencast") stops += 1;
        return Promise.resolve();
      },
    },
    width: 1280,
    height: 800,
    seq: 0,
    casting: false,
    castStarting: null,
  };
  (manager as unknown as { surfaces: Map<string, typeof surface> }).surfaces.set(
    surface.id,
    surface,
  );

  const first = manager.attach(surface.id);
  const second = manager.attach(surface.id);
  assert.equal(starts, 1);
  resolveStart();
  await Promise.all([first, second]);

  await manager.detach(surface.id, () => false);
  assert.equal(stops, 0);
  await manager.detach(surface.id);
  assert.equal(stops, 1);
});

test("browser open rejects a page that closes during initial navigation", async () => {
  const manager = new BrowserManager();
  let onClose = () => {};
  const page = {
    setViewportSize: async () => {},
    goto: async () => onClose(),
    on(event: string, handler: () => void) {
      if (event === "close") onClose = handler;
    },
  };
  const context = {
    newPage: async () => page,
    newCDPSession: async () => ({ on: () => {}, send: async () => {} }),
  };
  (manager as unknown as { context: typeof context }).context = context;

  await assert.rejects(
    manager.open({ url: "http://example.test" }),
    /browser surface closed during open/,
  );
  assert.deepEqual(manager.list(), []);
});

test("browser navigate rejects a page that closes during navigation", async () => {
  const manager = new BrowserManager();
  const surfaces = (manager as unknown as { surfaces: Map<string, unknown> }).surfaces;
  const surface = {
    id: "browser",
    handle: 1,
    page: {
      goto: async () => {
        surfaces.delete("browser");
      },
      url: () => "http://example.test/closed",
    },
    cdp: {},
    width: 1280,
    height: 800,
    seq: 0,
    casting: false,
    castStarting: null,
  };
  surfaces.set(surface.id, surface);

  await assert.rejects(
    manager.navigate(surface.id, "http://example.test/closed"),
    /browser surface closed during navigation/,
  );
});
