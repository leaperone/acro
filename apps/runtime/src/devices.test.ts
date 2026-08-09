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
        // 无 scopes 字段的旧记录 = 升级前配对,保留其当时的全部权限
        scopes: ["read", "control", "computer", "admin"],
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

test("grants scoped by pairing, and pre-scope devices keep full access", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-devices-scope-"));
  const file = path.join(directory, "devices.json");
  try {
    // 升级前配对的设备:记录里根本没有 scopes 字段
    const legacyToken = "a".repeat(64);
    fs.writeFileSync(
      file,
      JSON.stringify([
        {
          id: "legacy-device",
          name: "iPhone",
          createdAt: new Date().toISOString(),
          lastSeenAt: null,
          tokenHash: pairingAdmissionId(legacyToken),
        },
      ]),
    );

    const registry = new DeviceRegistry(file);
    assert.deepEqual(registry.auth(legacyToken)?.scopes, [
      "read",
      "control",
      "computer",
      "admin",
    ]);

    // 远程配对省略 scopes:默认不含整机控制与设备管理
    const fallback = registry.createGrant("iPad");
    assert.deepEqual(fallback.device.scopes, ["read", "control"]);

    // 显式授予:去重并固定为规范顺序
    const explicit = registry.createGrant("Mac", false, ["computer", "read", "read"]);
    assert.deepEqual(explicit.device.scopes, ["read", "computer"]);

    // 本机 grant 必须拿全 scope,否则桌面端会把自己锁在外面
    const local = registry.createGrant("本机", true, ["read"]);
    assert.deepEqual(local.device.scopes, ["read", "control", "computer", "admin"]);

    assert.throws(() => registry.createGrant("empty", false, []));

    // scope 必须真正落盘,重新加载后不得回退成全 scope
    const reloaded = new DeviceRegistry(file);
    assert.deepEqual(reloaded.auth(fallback.token)?.scopes, ["read", "control"]);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
