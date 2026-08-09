import assert from "node:assert/strict";
import test from "node:test";
import { DEFAULT_GRANT_SCOPES, Session } from "./models.ts";
import { E2eeAuthed, events, METHOD_SCOPES, methods } from "./rpc.ts";

test("computer input parameters stay within helper-safe bounds", () => {
  const key = methods["computer.key"].params;
  assert.equal(key.safeParse({ keyCode: -1 }).success, false);
  assert.equal(key.safeParse({ keyCode: 65535 }).success, true);
  assert.equal(key.safeParse({ keyCode: 65536 }).success, false);

  const type = methods["computer.type"].params;
  assert.equal(type.safeParse({ text: "x".repeat(2048) }).success, true);
  assert.equal(type.safeParse({ text: "x".repeat(2049) }).success, false);
});

test("browser input parameters stay within bounded control payloads", () => {
  const input = methods["browser.input"].params;
  assert.equal(
    input.safeParse({ browserId: "browser", event: { kind: "key", key: "x".repeat(64) } })
      .success,
    true,
  );
  assert.equal(
    input.safeParse({ browserId: "browser", event: { kind: "key", key: "x".repeat(65) } })
      .success,
    false,
  );
  assert.equal(
    input.safeParse({ browserId: "browser", event: { kind: "type", text: "x".repeat(2048) } })
      .success,
    true,
  );
  assert.equal(
    input.safeParse({ browserId: "browser", event: { kind: "type", text: "x".repeat(2049) } })
      .success,
    false,
  );
});

test("simulator methods accept only fixed-size UDID values", () => {
  const valid = "00000000-0000-0000-0000-000000000000";
  for (const method of [
    "simulator.boot",
    "simulator.shutdown",
    "simulator.attach",
    "simulator.detach",
  ] as const) {
    assert.equal(methods[method].params.safeParse({ udid: valid }).success, true);
    assert.equal(methods[method].params.safeParse({ udid: "x".repeat(36) }).success, false);
    assert.equal(methods[method].params.safeParse({ udid: "x".repeat(900_000) }).success, false);
  }
  assert.equal(
    methods["simulator.list"].result.safeParse([
      { udid: valid, name: "iPhone", state: "Booted", runtime: "iOS" },
    ]).success,
    true,
  );
  assert.equal(
    methods["simulator.list"].result.safeParse([
      { udid: "not-a-udid", name: "iPhone", state: "Booted", runtime: "iOS" },
    ]).success,
    false,
  );
});

test("session removal accepts only UUID session ids", () => {
  const params = methods["session.remove"].params;
  assert.equal(
    params.safeParse({ sessionId: "00000000-0000-4000-8000-000000000000" }).success,
    true,
  );
  assert.equal(params.safeParse({ sessionId: "../workspace-state.json" }).success, false);
});

test("agent session metadata stays backward-compatible and injection-safe", () => {
  const base = {
    id: "00000000-0000-4000-8000-000000000000",
    cwd: "/tmp",
    command: "codex",
    cols: 80,
    rows: 24,
    createdAt: new Date(0).toISOString(),
    alive: true,
    exitCode: null,
  };
  assert.equal(Session.parse(base).agent, null);
  assert.equal(
    Session.safeParse({
      ...base,
      agent: {
        provider: "codex",
        state: "working",
        providerSessionId: "session-1",
        codexHome: "/tmp/codex-home",
        managed: true,
        interrupted: false,
        updatedAt: new Date(0).toISOString(),
      },
    }).success,
    true,
  );
  for (const providerSessionId of ["--last", "bad\nid", "x".repeat(513)]) {
    assert.equal(
      Session.safeParse({
        ...base,
        agent: {
          provider: "codex",
          state: "working",
          providerSessionId,
          codexHome: "/tmp/codex-home",
          managed: true,
          interrupted: false,
          updatedAt: new Date(0).toISOString(),
        },
      }).success,
      false,
    );
  }
  assert.equal(
    Session.safeParse({
      ...base,
      agent: {
        provider: "codex",
        state: "working",
        providerSessionId: "session-1",
        codexHome: "/tmp/codex-home",
        accountFingerprint: "not-a-fingerprint",
        managed: true,
        interrupted: false,
        updatedAt: new Date(0).toISOString(),
      },
    }).success,
    false,
  );
});

test("agent creation and resume RPCs keep provider selection server-owned", () => {
  const create = methods["session.create"].params;
  assert.equal(create.safeParse({ agent: "codex", cols: 80, rows: 24 }).success, true);
  assert.equal(
    create.safeParse({ agent: "claude", command: "echo nope", cols: 80, rows: 24 }).success,
    false,
  );
  assert.equal(
    methods["session.resumeAgent"].params.safeParse({
      sessionId: "00000000-0000-4000-8000-000000000000",
    }).success,
    true,
  );
  assert.equal(
    methods["agent.capabilities"].result.safeParse({ providers: ["codex", "claude"] })
      .success,
    true,
  );
});

test("daemon restart requires explicit destructive intent", () => {
  const params = methods["daemon.restart"].params;
  assert.equal(params.safeParse({ force: true }).success, true);
  assert.equal(params.safeParse({ force: false }).success, false);
  assert.equal(params.safeParse({}).success, false);
});

test("every RPC method declares a scope, and privileged methods are not readable", () => {
  const declared = Object.keys(METHOD_SCOPES).sort();
  const defined = Object.keys(methods).sort();
  assert.deepEqual(declared, defined, "METHOD_SCOPES must cover exactly the method table");

  // Computer Use 等于整台 Mac 的键鼠与录屏,绝不能落进 read 或 control
  for (const [method, scope] of Object.entries(METHOD_SCOPES)) {
    if (method.startsWith("computer.")) {
      const shared = method === "computer.controlOwner" || method === "computer.permissions";
      assert.equal(shared ? scope === "read" : scope === "computer", true, method);
    }
    if (method.startsWith("device.")) assert.equal(scope, "admin", method);
  }

  // 只读家族不得被授予写权限档
  for (const method of ["fs.read", "fs.search", "git.diff", "git.status", "ports.list"]) {
    assert.equal(METHOD_SCOPES[method as keyof typeof METHOD_SCOPES], "read", method);
  }

  // 新配对默认不含整机控制与设备管理
  assert.deepEqual([...DEFAULT_GRANT_SCOPES], ["read", "control"]);
  assert.equal(DEFAULT_GRANT_SCOPES.includes("computer"), false);
  assert.equal(DEFAULT_GRANT_SCOPES.includes("admin"), false);
});

test("session events carry their workspace and stay backward-compatible", () => {
  // 旧 runtime 不发 workspaceId:必须仍能解析,并落到 null
  const legacy = events["session.exit"].safeParse({ sessionId: "s1", exitCode: 0 });
  assert.equal(legacy.success, true);
  assert.equal(legacy.success && legacy.data.workspaceId, null);

  const scoped = events["session.title"].safeParse({
    sessionId: "s1",
    title: "acro",
    workspaceId: "w1",
  });
  assert.equal(scoped.success && scoped.data.workspaceId, "w1");

  // authed 的 scopes 对旧 runtime 可缺省
  assert.equal(E2eeAuthed.safeParse({ t: "authed", deviceId: "d1" }).success, true);
  assert.equal(
    E2eeAuthed.safeParse({ t: "authed", deviceId: "d1", scopes: ["read"] }).success,
    true,
  );
  assert.equal(
    E2eeAuthed.safeParse({ t: "authed", deviceId: "d1", scopes: ["root"] }).success,
    false,
  );
});
