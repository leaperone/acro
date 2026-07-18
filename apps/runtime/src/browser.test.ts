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
