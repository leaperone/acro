import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { decodePairingOffer } from "@acro/protocol";
import { DeviceRegistry } from "./devices.ts";
import {
  createShareOffer,
  ensureBootstrapOffer,
  ensureLocalOffer,
  ServerIdentity,
  writeBootstrapOffer,
} from "./share.ts";

test("server identity is created once and corruption never rotates it", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-server-identity-"));
  const file = path.join(directory, "server-key.json");
  try {
    const first = new ServerIdentity(file);
    assert.deepEqual(new ServerIdentity(file).pub, first.pub);

    fs.writeFileSync(file, "null");
    assert.throws(() => new ServerIdentity(file), /invalid server identity/);
    assert.equal(fs.readFileSync(file, "utf8"), "null");
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("local offer stays private, reuses a valid grant, and rotates after revoke", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-local-offer-"));
  const identityFile = path.join(directory, "server-key.json");
  const devicesFile = path.join(directory, "devices.json");
  const offerFile = path.join(directory, "local-offer.txt");
  try {
    const registry = new DeviceRegistry(devicesFile);
    const identity = new ServerIdentity(identityFile);
    const first = ensureLocalOffer(registry, identity, 8790, offerFile);
    const reused = ensureLocalOffer(registry, identity, 8790, offerFile);

    assert.deepEqual(reused, first);
    assert.equal(fs.statSync(offerFile).mode & 0o777, 0o600);
    assert.equal(decodePairingOffer(fs.readFileSync(offerFile, "utf8")).token.length, 64);

    fs.rmSync(offerFile);
    const restarted = new DeviceRegistry(devicesFile);
    const rotated = ensureLocalOffer(restarted, identity, 8790, offerFile);
    assert.notEqual(rotated.deviceId, first.deviceId);
    assert.notEqual(rotated.offer, first.offer);
    assert.equal(restarted.auth(decodePairingOffer(first.offer).token), null);
    assert.equal(restarted.list().length, 1);
    assert.equal(fs.readFileSync(offerFile, "utf8").trim(), rotated.offer);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("failed offer publication rolls back the device grant", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-offer-rollback-"));
  const identityFile = path.join(directory, "server-key.json");
  const devicesFile = path.join(directory, "devices.json");
  const blockedOfferFile = path.join(directory, "blocked-offer");
  try {
    const registry = new DeviceRegistry(devicesFile);
    const identity = new ServerIdentity(identityFile);

    const unicode = createShareOffer(registry, identity, 8790, "test", ["例子.test:8790"]);
    assert.ok(decodePairingOffer(unicode.offer).endpoints.includes("例子.test:8790"));
    assert.equal(registry.remove(unicode.deviceId)?.id, unicode.deviceId);

    fs.mkdirSync(blockedOfferFile);
    assert.throws(() => ensureLocalOffer(registry, identity, 8790, blockedOfferFile));
    assert.deepEqual(registry.list(), []);

    const bootstrap = path.join(directory, "bootstrap-offer.txt");
    fs.mkdirSync(bootstrap);
    assert.throws(() => writeBootstrapOffer(registry, identity, 8790, bootstrap));
    assert.deepEqual(registry.list(), []);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("bootstrap offer is reused until a device has authenticated", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-bootstrap-retry-"));
  const identityFile = path.join(directory, "server-key.json");
  const devicesFile = path.join(directory, "devices.json");
  const localOfferFile = path.join(directory, "local-offer.txt");
  const offerFile = path.join(directory, "bootstrap-offer.txt");
  try {
    const registry = new DeviceRegistry(devicesFile);
    const identity = new ServerIdentity(identityFile);
    ensureLocalOffer(registry, identity, 8790, localOfferFile);
    fs.mkdirSync(offerFile);
    assert.throws(() => writeBootstrapOffer(registry, identity, 8790, offerFile));
    assert.equal(registry.list().length, 1);
    assert.equal(registry.list().some((device) => device.lastSeenAt !== null), false);

    fs.rmSync(offerFile, { recursive: true });
    const first = ensureBootstrapOffer(registry, identity, 8790, offerFile);
    const reused = ensureBootstrapOffer(registry, identity, 8790, offerFile);

    assert.deepEqual(reused, first);
    assert.equal(registry.list().length, 2);
    assert.equal(registry.auth(decodePairingOffer(first.offer).token)?.id, first.deviceId);
    assert.equal(registry.list().some((device) => device.lastSeenAt !== null), true);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("legacy HTTP local grants are revoked during local offer migration", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-local-migration-"));
  const identityFile = path.join(directory, "server-key.json");
  const devicesFile = path.join(directory, "devices.json");
  const offerFile = path.join(directory, "local-offer.txt");
  const oldToken = "a".repeat(64);
  try {
    fs.writeFileSync(
      devicesFile,
      JSON.stringify([
        {
          id: "legacy-local",
          name: "本机",
          createdAt: "2026-01-01T00:00:00.000Z",
          lastSeenAt: "2026-01-01T00:01:00.000Z",
          tokenHash: crypto.createHash("sha256").update(oldToken).digest("hex"),
        },
        {
          id: "legacy-local-duplicate",
          name: "本机",
          createdAt: "2026-01-01T00:02:00.000Z",
          lastSeenAt: null,
          tokenHash: "b".repeat(64),
        },
      ]),
    );
    const registry = new DeviceRegistry(devicesFile);
    const identity = new ServerIdentity(identityFile);

    assert.deepEqual(
      registry.migrateLegacyLocalGrants().map((device) => device.id),
      ["legacy-local", "legacy-local-duplicate"],
    );
    const replacement = ensureLocalOffer(registry, identity, 8790, offerFile);

    assert.notEqual(replacement.deviceId, "legacy-local");
    assert.equal(registry.auth(oldToken), null);
    assert.deepEqual(registry.list().map((device) => device.id), [replacement.deviceId]);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});
