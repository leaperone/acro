import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { pairingAdmissionId } from "@acro/protocol";
import { DeviceRegistry } from "./devices.ts";

test("device mutations replace memory only after state persists", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-devices-"));
  const file = path.join(directory, "devices.json");
  try {
    const registry = new DeviceRegistry(file);
    const grant = registry.createGrant("test");
    fs.rmSync(file);
    fs.mkdirSync(file);

    assert.throws(() => registry.remove(grant.device.id));
    assert.deepEqual(registry.list().map((device) => device.id), [grant.device.id]);
    const warn = console.warn;
    console.warn = () => {};
    try {
      assert.equal(registry.auth(grant.token)?.id, grant.device.id);
    } finally {
      console.warn = warn;
    }
    fs.rmSync(file, { recursive: true });
    assert.equal(registry.remove(grant.device.id)?.id, grant.device.id);
    assert.deepEqual(registry.list(), []);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("device state rejects a malformed entry without rewriting it", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-devices-invalid-"));
  const file = path.join(directory, "devices.json");
  const contents = JSON.stringify([{ id: "device" }]);
  try {
    fs.writeFileSync(file, contents);
    assert.throws(() => new DeviceRegistry(file));
    assert.equal(fs.readFileSync(file, "utf8"), contents);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("legacy device state without a local marker remains readable", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-devices-legacy-"));
  const file = path.join(directory, "devices.json");
  const device = {
    id: "device",
    name: "Legacy",
    createdAt: "2026-01-01T00:00:00.000Z",
    lastSeenAt: null,
    tokenHash: "0".repeat(64),
  };
  try {
    fs.writeFileSync(file, JSON.stringify([device]));
    const registry = new DeviceRegistry(file);
    assert.deepEqual(registry.list(), [
      {
        id: device.id,
        name: device.name,
        createdAt: device.createdAt,
        lastSeenAt: null,
      },
    ]);
    assert.deepEqual(registry.removeLocalGrants(), []);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("device admission ids recognize only persisted grants", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-devices-admission-"));
  const file = path.join(directory, "devices.json");
  try {
    const registry = new DeviceRegistry(file);
    const grant = registry.createGrant("test");
    assert.equal(registry.hasAdmissionId(pairingAdmissionId(grant.token)), true);
    assert.equal(registry.hasAdmissionId("0".repeat(64)), false);
    assert.equal(registry.hasAdmissionId("not-a-hash"), false);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
