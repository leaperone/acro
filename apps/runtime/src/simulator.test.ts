import assert from "node:assert/strict";
import test from "node:test";
import { SimulatorManager } from "./simulator.ts";

test("simulator detach announces the channel that stopped polling", () => {
  const manager = new SimulatorManager();
  const timer = setInterval(() => {}, 60_000);
  const abortController = new AbortController();
  const state = { handle: 7, seq: 0, timer, abortController };
  (manager as unknown as { attached: Map<string, typeof state> }).attached.set("sim", state);
  let detached: [string, number] | null = null;
  manager.on("detached", (udid: string, channel: number) => {
    detached = [udid, channel];
  });

  manager.detach("sim");

  assert.deepEqual(detached, ["sim", 7]);
  assert.equal(abortController.signal.aborted, true);
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

test("simulator commands share a bounded executor", async () => {
  let active = 0;
  let maxActive = 0;
  const manager = new SimulatorManager(async (_args, options) => {
    assert.equal(options.timeoutMs, 60_000);
    active += 1;
    maxActive = Math.max(maxActive, active);
    await new Promise((resolve) => setTimeout(resolve, 10));
    active -= 1;
    return JSON.stringify({ devices: {} });
  }, 2);

  await Promise.all(Array.from({ length: 6 }, () => manager.list()));

  assert.equal(maxActive, 2);
});

test("simulator queue rejects overflow and removes aborted requests", async () => {
  let calls = 0;
  let releaseFirst!: () => void;
  let markStarted!: () => void;
  const started = new Promise<void>((resolve) => {
    markStarted = resolve;
  });
  const manager = new SimulatorManager(async () => {
    calls += 1;
    if (calls === 1) {
      markStarted();
      await new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });
    }
    return JSON.stringify({ devices: {} });
  }, 1, 1);
  const first = manager.list();
  await started;
  const controller = new AbortController();
  const queued = manager.list(controller.signal);
  await assert.rejects(manager.list(), /queue full/);

  controller.abort(new Error("connection closed"));

  await assert.rejects(queued, /connection closed/);
  assert.equal(calls, 1);
  releaseFirst();
  await first;
});

test("simulator detach aborts an active screenshot and suppresses stale frames", async () => {
  let screenshotSignal: AbortSignal | undefined;
  let markScreenshotStarted!: () => void;
  const screenshotStarted = new Promise<void>((resolve) => {
    markScreenshotStarted = resolve;
  });
  const manager = new SimulatorManager(async (args, options) => {
    if (args[0] === "list") {
      return JSON.stringify({
        devices: {
          "com.apple.CoreSimulator.SimRuntime.iOS": [
            { udid: "sim", name: "iPhone", state: "Booted" },
          ],
        },
      });
    }
    assert.equal(options.timeoutMs, 10_000);
    screenshotSignal = options.signal;
    markScreenshotStarted();
    return new Promise<string>((_resolve, reject) => {
      options.signal?.addEventListener("abort", () => reject(options.signal!.reason), {
        once: true,
      });
    });
  });
  let frames = 0;
  manager.on("frame", () => {
    frames += 1;
  });

  await manager.attach("sim");
  await screenshotStarted;
  manager.detach("sim");
  await manager.shutdownManager();

  assert.equal(screenshotSignal?.aborted, true);
  assert.equal(frames, 0);
});

test("simulator attach cannot publish after shutdown overtakes its device lookup", async () => {
  let releaseList!: () => void;
  let markListStarted!: () => void;
  const listStarted = new Promise<void>((resolve) => {
    markListStarted = resolve;
  });
  const manager = new SimulatorManager(async (args) => {
    if (args[0] === "list") {
      markListStarted();
      await new Promise<void>((resolve) => {
        releaseList = resolve;
      });
      return JSON.stringify({
        devices: {
          "com.apple.CoreSimulator.SimRuntime.iOS": [
            { udid: "sim", name: "iPhone", state: "Booted" },
          ],
        },
      });
    }
    return "";
  });

  const attach = manager.attach("sim");
  await listStarted;
  await manager.shutdown("sim");
  releaseList();

  await assert.rejects(attach, /operation changed/);
  assert.equal(
    (manager as unknown as { attached: Map<string, unknown> }).attached.size,
    0,
  );
});

test("simulator managers use distinct screenshot paths", async () => {
  const screenshotPaths: string[] = [];
  const runner = async (args: string[]) => {
    if (args[0] === "list") {
      return JSON.stringify({
        devices: {
          "com.apple.CoreSimulator.SimRuntime.iOS": [
            { udid: "sim", name: "iPhone", state: "Booted" },
          ],
        },
      });
    }
    screenshotPaths.push(args.at(-1)!);
    throw new Error("capture stopped");
  };
  const first = new SimulatorManager(runner);
  const second = new SimulatorManager(runner);

  await Promise.all([first.attach("sim"), second.attach("sim")]);
  for (let attempt = 0; attempt < 100 && screenshotPaths.length < 2; attempt += 1) {
    await new Promise<void>((resolve) => setImmediate(resolve));
  }
  first.detach("sim");
  second.detach("sim");
  await Promise.all([first.shutdownManager(), second.shutdownManager()]);

  assert.equal(screenshotPaths.length, 2);
  assert.notEqual(screenshotPaths[0], screenshotPaths[1]);
});

test("simulator shutdown waits for active non-capture commands", async () => {
  let releaseBoot!: () => void;
  let markBootStarted!: () => void;
  const bootStarted = new Promise<void>((resolve) => {
    markBootStarted = resolve;
  });
  const manager = new SimulatorManager(async (args) => {
    if (args[0] === "boot") {
      markBootStarted();
      await new Promise<void>((resolve) => {
        releaseBoot = resolve;
      });
    }
    return "";
  });
  const boot = manager.boot("sim");
  await bootStarted;
  let shutdownFinished = false;
  const shutdown = manager.shutdownManager().then(() => {
    shutdownFinished = true;
  });

  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(shutdownFinished, false);
  releaseBoot();
  await boot;
  await shutdown;
  assert.equal(shutdownFinished, true);
});
