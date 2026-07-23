import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  accountFingerprintMatches,
  agentStateFromHook,
  buildAgentArgs,
  mergeCodexHooks,
  normalizeProviderSessionId,
  readClaudeAccountFingerprint,
  readCodexAccountFingerprint,
} from "./agent.ts";

test("provider hook events map to the smallest useful agent state", () => {
  assert.equal(agentStateFromHook("UserPromptSubmit", null), "working");
  assert.equal(agentStateFromHook("PreToolUse", "Bash"), "working");
  assert.equal(agentStateFromHook("PreToolUse", "request_user_input"), "waiting");
  assert.equal(agentStateFromHook("PermissionRequest", null), "waiting");
  assert.equal(agentStateFromHook("Stop", null), "done");
  assert.equal(agentStateFromHook("StopFailure", null), "error");
  assert.equal(agentStateFromHook("Stop", null, true), undefined);
  assert.equal(agentStateFromHook("PermissionRequest", null, true), "waiting");
  assert.equal(agentStateFromHook("unknown", null), undefined);
});

test("provider session ids reject option and control-character injection", () => {
  assert.equal(normalizeProviderSessionId(" session-1 "), "session-1");
  assert.equal(normalizeProviderSessionId("--last"), null);
  assert.equal(normalizeProviderSessionId("bad\nid"), null);
  assert.equal(normalizeProviderSessionId("x".repeat(513)), null);
});

test("resume targets stay a single direct argv value", () => {
  const id = "session; touch /tmp/not-executed";
  assert.deepEqual(buildAgentArgs("codex", id), ["resume", id]);
  assert.deepEqual(buildAgentArgs("claude", id).slice(-2), ["--resume", id]);
  assert.throws(() => buildAgentArgs("codex", "--last"), /invalid provider session id/);
});

test("Codex hook merge preserves user hooks and stays idempotent", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-hooks-"));
  const file = path.join(directory, "hooks.json");
  const command = "/bin/sh /tmp/acro-hook.sh codex";
  try {
    fs.writeFileSync(
      file,
      JSON.stringify({
        version: 1,
        hooks: {
          Stop: [{ hooks: [{ type: "command", command: "user-audit" }] }],
          CustomEvent: [{ hooks: [{ type: "command", command: "user-custom" }] }],
        },
      }),
    );
    mergeCodexHooks(file, command);
    mergeCodexHooks(file, command);

    const config = JSON.parse(fs.readFileSync(file, "utf8")) as {
      version: number;
      hooks: Record<string, Array<{ hooks?: Array<{ command?: string }> }>>;
    };
    assert.equal(config.version, 1);
    assert.equal(config.hooks.CustomEvent?.[0]?.hooks?.[0]?.command, "user-custom");
    assert.equal(config.hooks.Stop?.[0]?.hooks?.[0]?.command, "user-audit");
    assert.equal(
      config.hooks.Stop?.flatMap((entry) => entry.hooks ?? []).filter(
        (hook) => hook.command === command,
      ).length,
      1,
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("unmanaged Claude launch args omit Acro settings", () => {
  assert.deepEqual(buildAgentArgs("claude", undefined, false), []);
});

test("account fingerprints ignore token refreshes and detect identity switches", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "acro-identity-"));
  const payload = (accountId: string) =>
    Buffer.from(
      JSON.stringify({
        email: "user@example.com",
        "https://api.openai.com/auth": {
          chatgpt_account_id: accountId,
          workspace_account_id: `workspace-${accountId}`,
        },
      }),
    ).toString("base64url");
  const writeAuth = (accountId: string, refreshToken: string) =>
    fs.writeFileSync(
      path.join(directory, "auth.json"),
      JSON.stringify({
        tokens: {
          id_token: `header.${payload(accountId)}.signature`,
          account_id: accountId,
          refresh_token: refreshToken,
        },
      }),
    );
  try {
    writeAuth("account-a", "refresh-a");
    const first = readCodexAccountFingerprint(directory);
    writeAuth("account-a", "refresh-b");
    assert.equal(readCodexAccountFingerprint(directory), first);
    writeAuth("account-b", "refresh-c");
    assert.notEqual(readCodexAccountFingerprint(directory), first);

    const claude = readClaudeAccountFingerprint(
      JSON.stringify({
        orgId: "org-a",
        email: "user@example.com",
      }),
    );
    assert.equal(
      readClaudeAccountFingerprint({
        orgId: "ORG-A",
        email: "USER@example.com",
      }),
      claude,
    );
    assert.notEqual(
      readClaudeAccountFingerprint({
        orgId: "org-b",
        email: "user@example.com",
      }),
      claude,
    );
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test("resume identity matching fails closed", () => {
  const fingerprint = "a".repeat(64);
  assert.equal(accountFingerprintMatches(fingerprint, fingerprint), true);
  assert.equal(accountFingerprintMatches(fingerprint, "b".repeat(64)), false);
  assert.equal(accountFingerprintMatches(undefined, fingerprint), false);
  assert.equal(accountFingerprintMatches(fingerprint, null), false);
});
