import assert from "node:assert/strict";
import test from "node:test";
import { SimulatorManager } from "./simulator.ts";

test("simulator detach announces the channel that stopped polling", () => {
  const manager = new SimulatorManager();
  const timer = setInterval(() => {}, 60_000);
  const state = { handle: 7, seq: 0, timer };
  (manager as unknown as { attached: Map<string, typeof state> }).attached.set("sim", state);
  let detached: [string, number] | null = null;
  manager.on("detached", (udid: string, channel: number) => {
    detached = [udid, channel];
  });

  manager.detach("sim");

  assert.deepEqual(detached, ["sim", 7]);
});

test("simulator attach rejects unknown UDIDs before polling", async () => {
  const manager = new SimulatorManager();
  manager.list = async () => [
    { udid: "real-simulator", name: "iPhone", state: "Shutdown", runtime: "iOS" },
  ];

  await assert.rejects(manager.attach("forged-simulator"), /simulator not found/);
  assert.equal(
    (manager as unknown as { attached: Map<string, unknown> }).attached.size,
    0,
  );
});
