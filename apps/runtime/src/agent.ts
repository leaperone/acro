import { execFile, spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import type { AgentSession } from "@acro/protocol";
import { ensurePrivateDirectory, paths, PRIVATE_FILE_MODE } from "./paths.ts";
import { writeJsonAtomic } from "./store.ts";

export type AgentProvider = AgentSession["provider"];

export interface AgentHookUpdate {
  sessionId: string;
  provider: AgentProvider;
  state?: AgentSession["state"];
  providerSessionId?: string;
  updatedAt: string;
}

export interface AgentLaunch {
  executable: string;
  args: string[];
  env: Record<string, string>;
  command: string;
  tracked: boolean;
  managed: boolean;
  accountFingerprint?: string;
  codexHome?: string;
}

const HOOK_EVENTS: Record<AgentProvider, readonly string[]> = {
  claude: [
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PostToolUseFailure",
    "Stop",
    "StopFailure",
  ],
  codex: [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "Stop",
  ],
};
const MAX_HOOK_BODY_BYTES = 1024 * 1024;

export function normalizeProviderSessionId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const id = value.trim();
  if (
    id.length === 0 ||
    id.length > 512 ||
    id.startsWith("-") ||
    /[\u0000-\u001f\u007f]/.test(id)
  ) {
    return null;
  }
  return id;
}

export function agentStateFromHook(
  eventName: unknown,
  toolName: unknown,
  child = false,
): AgentSession["state"] | undefined {
  let state: AgentSession["state"] | undefined;
  if (eventName === "PermissionRequest") state = "waiting";
  if (
    eventName === "PreToolUse" &&
    (toolName === "AskUserQuestion" || toolName === "request_user_input")
  ) {
    state = "waiting";
  } else if (eventName === "StopFailure") state = "error";
  else if (eventName === "Stop") state = "done";
  else if (
    eventName === "SessionStart" ||
    eventName === "UserPromptSubmit" ||
    eventName === "PreToolUse" ||
    eventName === "PostToolUse" ||
    eventName === "PostToolUseFailure"
  ) {
    state = "working";
  }
  return child && state !== "waiting" ? undefined : state;
}

export function buildAgentArgs(
  provider: AgentProvider,
  providerSessionId?: string,
  includeHooks = true,
): string[] {
  if (providerSessionId && !normalizeProviderSessionId(providerSessionId)) {
    throw new Error("invalid provider session id");
  }
  if (provider === "claude") {
    return [
      ...(includeHooks ? ["--settings", paths.claudeAgentSettings] : []),
      ...(providerSessionId ? ["--resume", providerSessionId] : []),
    ];
  }
  return providerSessionId ? ["resume", providerSessionId] : [];
}

export class AgentManager {
  private readonly token = crypto.randomBytes(32).toString("hex");
  private readonly onUpdate: (update: AgentHookUpdate) => Promise<void>;
  private server: http.Server | null = null;
  private hooksReady = false;
  private readonly codexReady = new Map<string, Promise<void>>();
  private readonly availability = new Map<AgentProvider, Promise<void>>();

  constructor(onUpdate: (update: AgentHookUpdate) => Promise<void>) {
    this.onUpdate = onUpdate;
  }

  async start(): Promise<void> {
    this.hooksReady = false;
    try {
      ensurePrivateDirectory(paths.agentHooks);
      this.writeHookScript();
      this.writeClaudeSettings();
      this.server = http.createServer((request, response) => {
        void this.handleHook(request, response);
      });
      await new Promise<void>((resolve, reject) => {
        this.server!.once("error", reject);
        this.server!.listen(0, "127.0.0.1", () => resolve());
      });
      const address = this.server.address();
      if (!address || typeof address === "string") throw new Error("agent hook listener failed");
      writePrivateText(
        paths.agentHookEndpoint,
        `ACRO_AGENT_HOOK_PORT='${address.port}'\nACRO_AGENT_HOOK_TOKEN='${this.token}'\n`,
      );
      this.hooksReady = true;
    } catch (error) {
      try {
        fs.rmSync(paths.agentHookEndpoint, { force: true });
      } catch {}
      await this.stop();
      throw error;
    }
  }

  async stop(): Promise<void> {
    this.hooksReady = false;
    const server = this.server;
    this.server = null;
    if (!server?.listening) return;
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  async launch(
    provider: AgentProvider,
    sessionId: string,
    cwd: string,
    providerSessionId?: string,
    savedCodexHome?: string,
    savedAccountFingerprint?: string,
    options: { deadline?: number; tracking?: boolean } = {},
  ): Promise<AgentLaunch> {
    assertBeforeDeadline(options.deadline);
    await this.requireProvider(provider, options.deadline);
    assertBeforeDeadline(options.deadline);
    const shell = loginShell();
    const codexHome =
      provider === "codex"
        ? (savedCodexHome ?? (await resolveCodexHome(shell, options.deadline)))
        : undefined;
    const accountFingerprint =
      provider === "codex"
        ? readCodexAccountFingerprint(codexHome!)
        : await resolveClaudeAccountFingerprint(shell, options.deadline);
    assertBeforeDeadline(options.deadline);
    if (
      providerSessionId &&
      !accountFingerprintMatches(savedAccountFingerprint, accountFingerprint)
    ) {
      throw new Error("Agent account identity changed; automatic resume refused");
    }
    let trackingReady = options.tracking !== false && this.hooksReady;
    if (codexHome && trackingReady) {
      let ready = this.codexReady.get(codexHome!);
      if (!ready) {
        ready = this.prepareCodexHooks(cwd, shell, codexHome!, options.deadline);
        this.codexReady.set(codexHome!, ready);
      }
      try {
        await waitBeforeDeadline(ready, options.deadline);
      } catch (error) {
        if (this.codexReady.get(codexHome) === ready) this.codexReady.delete(codexHome);
        if (deadlineExpired(options.deadline)) throw new Error("Agent recovery deadline exceeded");
        trackingReady = false;
        try {
          removeCodexHooks(path.join(codexHome, "hooks.json"), this.hookCommand("codex"));
        } catch {}
        console.warn(`[runtime] Codex hooks unavailable: ${(error as Error).message}`);
      }
    }
    assertBeforeDeadline(options.deadline);
    const providerArgs = buildAgentArgs(provider, providerSessionId, trackingReady);
    return {
      executable: shell,
      args:
        codexHome
          ? [
              "-lic",
              'export CODEX_HOME="$1"; shift; exec codex "$@"',
              "acro-agent",
              codexHome!,
              ...providerArgs,
            ]
          : ["-lic", `exec ${provider} "$@"`, "acro-agent", ...providerArgs],
      env: trackingReady
        ? {
            ACRO_AGENT_HOOK_ENDPOINT: paths.agentHookEndpoint,
            ACRO_SESSION_ID: sessionId,
          }
        : {},
      command: provider,
      tracked: trackingReady,
      managed: trackingReady && accountFingerprint !== null,
      ...(accountFingerprint ? { accountFingerprint } : {}),
      ...(codexHome ? { codexHome } : {}),
    };
  }

  async capabilities(): Promise<AgentProvider[]> {
    if (!this.hooksReady) return [];
    const providers: AgentProvider[] = [];
    for (const provider of ["codex", "claude"] as const) {
      try {
        await this.requireProvider(provider);
        providers.push(provider);
      } catch {}
    }
    return providers;
  }

  private async requireProvider(provider: AgentProvider, deadline?: number): Promise<void> {
    let available = this.availability.get(provider);
    if (!available) {
      available = assertProviderAvailable(provider, deadline);
      this.availability.set(provider, available);
    }
    try {
      await waitBeforeDeadline(available, deadline);
    } catch (error) {
      if (this.availability.get(provider) === available) this.availability.delete(provider);
      throw error;
    }
  }

  private writeHookScript(): void {
    writePrivateText(
      paths.agentHookScript,
      [
        "#!/bin/sh",
        "payload=$(cat)",
        "provider=$1",
        'if [ -z "$ACRO_AGENT_HOOK_ENDPOINT" ] || [ ! -r "$ACRO_AGENT_HOOK_ENDPOINT" ] || [ -z "$ACRO_SESSION_ID" ]; then exit 0; fi',
        '. "$ACRO_AGENT_HOOK_ENDPOINT" 2>/dev/null || exit 0',
        'if [ -z "$ACRO_AGENT_HOOK_PORT" ] || [ -z "$ACRO_AGENT_HOOK_TOKEN" ]; then exit 0; fi',
        'printf \'%s\' "$payload" | /usr/bin/curl -sS -X POST "http://127.0.0.1:${ACRO_AGENT_HOOK_PORT}/hook/${provider}" \\',
        "  --connect-timeout 0.5 --max-time 1.5 --noproxy 127.0.0.1 \\",
        '  -H "Content-Type: application/json" \\',
        '  -H "X-Acro-Agent-Hook-Token: ${ACRO_AGENT_HOOK_TOKEN}" \\',
        '  -H "X-Acro-Session-Id: ${ACRO_SESSION_ID}" \\',
        "  --data-binary @- >/dev/null 2>&1 || true",
        "exit 0",
        "",
      ].join("\n"),
      0o700,
    );
  }

  private hookCommand(provider: AgentProvider): string {
    return `/bin/sh ${shellQuote(paths.agentHookScript)} ${provider}`;
  }

  private writeClaudeSettings(): void {
    const command = this.hookCommand("claude");
    writeJsonAtomic(paths.claudeAgentSettings, {
      hooks: Object.fromEntries(
        HOOK_EVENTS.claude.map((event) => [
          event,
          [
            {
              ...(event.includes("ToolUse") || event === "PermissionRequest"
                ? { matcher: "*" }
                : {}),
              hooks: [{ type: "command", command, timeout: 5 }],
            },
          ],
        ]),
      ),
    });
  }

  private async prepareCodexHooks(
    cwd: string,
    shell: string,
    codexHome: string,
    deadline?: number,
  ): Promise<void> {
    fs.mkdirSync(codexHome, { recursive: true });
    const command = this.hookCommand("codex");
    mergeCodexHooks(path.join(codexHome, "hooks.json"), command);
    await trustCodexHooks(shell, codexHome, command, cwd, deadline);
  }

  private async handleHook(
    request: http.IncomingMessage,
    response: http.ServerResponse,
  ): Promise<void> {
    const finish = (statusCode: number): void => {
      response.statusCode = statusCode;
      response.end();
    };
    const requestToken = request.headers["x-acro-agent-hook-token"];
    if (
      request.method !== "POST" ||
      typeof requestToken !== "string" ||
      !safeEqual(requestToken, this.token)
    ) {
      request.resume();
      finish(401);
      return;
    }
    const provider =
      request.url === "/hook/codex"
        ? "codex"
        : request.url === "/hook/claude"
          ? "claude"
          : null;
    const sessionId = request.headers["x-acro-session-id"];
    if (!provider || typeof sessionId !== "string") {
      request.resume();
      finish(204);
      return;
    }
    try {
      const payload = await readJsonBody(request);
      const isCodexChild = provider === "codex" && typeof payload.agent_id === "string";
      const providerSessionId =
        isCodexChild
          ? null
          : normalizeProviderSessionId(payload.session_id);
      const state = agentStateFromHook(
        payload.hook_event_name,
        payload.tool_name,
        isCodexChild,
      );
      if (providerSessionId || state) {
        await this.onUpdate({
          sessionId,
          provider,
          ...(state ? { state } : {}),
          ...(providerSessionId ? { providerSessionId } : {}),
          updatedAt: new Date().toISOString(),
        });
      }
    } catch {
      // Provider hooks are telemetry. Invalid payloads never block the Agent.
    }
    finish(204);
  }
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

function writePrivateText(file: string, content: string, mode = PRIVATE_FILE_MODE): void {
  ensurePrivateDirectory(path.dirname(file));
  const temporary = path.join(path.dirname(file), `.${path.basename(file)}.tmp`);
  fs.writeFileSync(temporary, content, { mode });
  fs.chmodSync(temporary, mode);
  fs.renameSync(temporary, file);
}

function safeEqual(left: string, right: string): boolean {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

export function accountFingerprintMatches(
  saved: string | undefined,
  current: string | null,
): boolean {
  return Boolean(saved && current && safeEqual(saved, current));
}

async function readJsonBody(request: http.IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let bytes = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    bytes += buffer.byteLength;
    if (bytes > MAX_HOOK_BODY_BYTES) throw new Error("agent hook payload too large");
    chunks.push(buffer);
  }
  const parsed = JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("invalid agent hook payload");
  }
  return parsed as Record<string, unknown>;
}

interface JsonRpcResponse {
  id?: number;
  result?: unknown;
  error?: { message?: string };
}

async function trustCodexHooks(
  shell: string,
  codexHome: string,
  command: string,
  cwd: string,
  deadline?: number,
): Promise<void> {
  const trustTimeoutMs = timeoutBeforeDeadline(deadline, 10_000);
  const child = spawn(shell, [
    "-lic",
    'export CODEX_HOME="$1"; shift; exec codex "$@"',
    "acro-hook-trust",
    codexHome,
    "app-server",
  ], {
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const pending = new Map<
    number,
    { resolve: (value: unknown) => void; reject: (error: Error) => void }
  >();
  let nextId = 1;
  let stdout = "";
  child.stderr.resume();
  child.stdout.setEncoding("utf8").on("data", (chunk: string) => {
    stdout += chunk;
    for (;;) {
      const newline = stdout.indexOf("\n");
      if (newline === -1) break;
      const line = stdout.slice(0, newline).trim();
      stdout = stdout.slice(newline + 1);
      if (!line) continue;
      try {
        const message = JSON.parse(line) as JsonRpcResponse;
        if (typeof message.id !== "number") continue;
        const waiter = pending.get(message.id);
        if (!waiter) continue;
        pending.delete(message.id);
        if (message.error) {
          waiter.reject(new Error(message.error.message ?? "Codex app-server error"));
        }
        else waiter.resolve(message.result);
      } catch {}
    }
  });
  const fail = (error: Error): void => {
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
  };
  child.on("error", fail);
  child.on("exit", (code) => {
    if (pending.size > 0) fail(new Error(`Codex app-server exited ${code}`));
  });
  const request = (method: string, params?: Record<string, unknown>): Promise<unknown> => {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      child.stdin.write(
        `${JSON.stringify({ id, method, ...(params ? { params } : {}) })}\n`,
      );
    });
  };
  const timeout = setTimeout(() => {
    child.kill("SIGKILL");
    fail(new Error("Codex hook trust timed out"));
  }, trustTimeoutMs);
  try {
    await request("initialize", {
      clientInfo: { name: "acro", title: "Acro", version: "0.1.0" },
    });
    child.stdin.write(`${JSON.stringify({ method: "initialized" })}\n`);
    const listed = collectHookListings(await request("hooks/list", { cwds: [cwd] })).filter(
      (entry) => entry.command === command,
    );
    if (listed.length < HOOK_EVENTS.codex.length) {
      throw new Error("Codex did not load Acro hooks");
    }
    const untrusted = listed.filter((entry) => entry.trustStatus !== "trusted");
    if (untrusted.length > 0) {
      await request("config/batchWrite", {
        edits: [
          {
            keyPath: "hooks.state",
            value: Object.fromEntries(
              untrusted.map((entry) => [entry.key, { trusted_hash: entry.currentHash }]),
            ),
            mergeStrategy: "upsert",
          },
        ],
        reloadUserConfig: true,
      });
    }
    const verified = collectHookListings(await request("hooks/list", { cwds: [cwd] })).filter(
      (entry) => entry.command === command,
    );
    if (
      verified.length < HOOK_EVENTS.codex.length ||
      verified.some((entry) => entry.trustStatus !== "trusted")
    ) {
      throw new Error("Codex did not trust Acro hooks");
    }
  } finally {
    clearTimeout(timeout);
    child.stdin.end();
    await new Promise<void>((resolve) => {
      const reapTimeoutMs = Math.min(1500, Math.max(0, (deadline ?? Infinity) - Date.now()));
      const reap = setTimeout(() => {
        child.kill("SIGKILL");
        resolve();
      }, reapTimeoutMs);
      child.once("exit", () => {
        clearTimeout(reap);
        resolve();
      });
    });
  }
}

function loginShell(): string {
  return process.env.SHELL ?? (process.platform === "darwin" ? "/bin/zsh" : "/bin/bash");
}

function assertProviderAvailable(provider: AgentProvider, deadline?: number): Promise<void> {
  const shell = loginShell();
  const lookup = path.basename(shell) === "zsh" ? `whence -p ${provider}` : `type -P ${provider}`;
  return new Promise((resolve, reject) => {
    execFile(
      shell,
      ["-lic", `${lookup} >/dev/null`],
      { timeout: timeoutBeforeDeadline(deadline, 5000), maxBuffer: 64 * 1024 },
      (error) => {
        if (error) {
          reject(new Error(`${provider} CLI is not installed in the login shell`));
          return;
        }
        resolve();
      },
    );
  });
}

function resolveCodexHome(shell: string, deadline?: number): Promise<string> {
  const marker = "__ACRO_CODEX_HOME__";
  return new Promise((resolve, reject) => {
    execFile(
      shell,
      ["-lic", `printf '${marker}%s\\n' "\${CODEX_HOME:-\$HOME/.codex}"`],
      { timeout: timeoutBeforeDeadline(deadline, 5000), maxBuffer: 64 * 1024 },
      (error, stdout) => {
        const line = stdout
          .split("\n")
          .find((candidate) => candidate.startsWith(marker));
        const codexHome = line?.slice(marker.length);
        if (error || !codexHome || !path.isAbsolute(codexHome)) {
          reject(new Error("Codex home is unavailable in the login shell"));
          return;
        }
        try {
          resolve(fs.realpathSync.native(codexHome));
        } catch {
          resolve(path.resolve(codexHome));
        }
      },
    );
  });
}

export function readCodexAccountFingerprint(codexHome: string): string | null {
  try {
    const auth = readJsonRecord(fs.readFileSync(path.join(codexHome, "auth.json"), "utf8"));
    if (!auth) return null;
    const apiKey =
      typeof auth.OPENAI_API_KEY === "string" && auth.OPENAI_API_KEY.trim()
        ? auth.OPENAI_API_KEY.trim()
        : null;
    if (apiKey) return fingerprintIdentity("codex-api-key", [apiKey]);
    const tokens = readJsonRecord(auth.tokens);
    const idToken = normalizeIdentityField(tokens?.id_token ?? tokens?.idToken);
    const payload = idToken ? readJwtPayload(idToken) : null;
    const authClaims = readJsonRecord(payload?.["https://api.openai.com/auth"]);
    const profileClaims = readJsonRecord(payload?.["https://api.openai.com/profile"]);
    const providerAccountId = normalizeIdentityField(
      tokens?.account_id ??
        tokens?.accountId ??
        authClaims?.chatgpt_account_id ??
        payload?.chatgpt_account_id,
    );
    const workspaceAccountId = normalizeIdentityField(
      authClaims?.workspace_account_id ??
        tokens?.account_id ??
        tokens?.accountId ??
        payload?.chatgpt_account_id,
    );
    if (!providerAccountId && !workspaceAccountId) return null;
    return fingerprintIdentity("codex", [
      providerAccountId,
      workspaceAccountId,
      normalizeIdentityField(payload?.email ?? profileClaims?.email),
    ]);
  } catch {
    return null;
  }
}

function resolveClaudeAccountFingerprint(shell: string, deadline?: number): Promise<string | null> {
  return new Promise((resolve) => {
    execFile(
      shell,
      ["-lic", "exec claude auth status --json"],
      { timeout: timeoutBeforeDeadline(deadline, 5000), maxBuffer: 64 * 1024 },
      (error, stdout) => {
        if (error) return resolve(null);
        resolve(readClaudeAccountFingerprint(stdout));
      },
    );
  });
}

function deadlineExpired(deadline?: number): boolean {
  return deadline !== undefined && Date.now() >= deadline;
}

function assertBeforeDeadline(deadline?: number): void {
  if (deadlineExpired(deadline)) throw new Error("Agent recovery deadline exceeded");
}

function timeoutBeforeDeadline(deadline: number | undefined, maximumMs: number): number {
  assertBeforeDeadline(deadline);
  return Math.max(1, Math.min(maximumMs, (deadline ?? Infinity) - Date.now()));
}

async function waitBeforeDeadline<T>(promise: Promise<T>, deadline?: number): Promise<T> {
  if (deadline === undefined) return promise;
  const timeoutMs = timeoutBeforeDeadline(deadline, deadline - Date.now());
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<T>((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error("Agent recovery deadline exceeded")), timeoutMs);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

export function readClaudeAccountFingerprint(statusOutput: unknown): string | null {
  const status = readJsonRecord(statusOutput);
  const accountId = normalizeIdentityField(status?.accountUuid ?? status?.accountId);
  const organizationId = normalizeIdentityField(
    status?.organizationUuid ?? status?.organizationId ?? status?.orgId,
  );
  if (!accountId && !organizationId) return null;
  return fingerprintIdentity("claude", [
    accountId,
    organizationId,
    normalizeIdentityField(status?.email ?? status?.emailAddress),
  ]);
}

function fingerprintIdentity(provider: string, fields: Array<string | null>): string | null {
  if (fields.every((field) => field === null)) return null;
  return crypto
    .createHash("sha256")
    .update(JSON.stringify([provider, ...fields]))
    .digest("hex");
}

function normalizeIdentityField(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim().toLowerCase() : null;
}

function readJsonRecord(value: unknown): Record<string, unknown> | null {
  try {
    const parsed = typeof value === "string" ? (JSON.parse(value) as unknown) : value;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function readJwtPayload(token: string): Record<string, unknown> | null {
  const payload = token.split(".")[1];
  if (!payload) return null;
  try {
    return readJsonRecord(Buffer.from(payload, "base64url").toString("utf8"));
  } catch {
    return null;
  }
}

export function mergeCodexHooks(file: string, command: string): void {
  updateCodexHooks(file, command, true);
}

function removeCodexHooks(file: string, command: string): void {
  updateCodexHooks(file, command, false);
}

function updateCodexHooks(file: string, command: string, install: boolean): void {
  const target =
    fs.existsSync(file) && fs.lstatSync(file).isSymbolicLink() ? fs.realpathSync(file) : file;
  let config: Record<string, unknown> = {};
  if (fs.existsSync(target)) {
    const parsed = JSON.parse(fs.readFileSync(target, "utf8")) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error(`invalid Codex hooks config: ${target}`);
    }
    config = parsed as Record<string, unknown>;
  }
  const currentHooks =
    config.hooks && typeof config.hooks === "object" && !Array.isArray(config.hooks)
      ? (config.hooks as Record<string, unknown>)
      : {};
  const hooks: Record<string, unknown> = { ...currentHooks };
  for (const event of HOOK_EVENTS.codex) {
    const definitions = Array.isArray(currentHooks[event]) ? currentHooks[event] : [];
    const cleaned = definitions.flatMap((definition) => {
      if (!definition || typeof definition !== "object" || Array.isArray(definition)) {
        return [definition];
      }
      const record = definition as Record<string, unknown>;
      if (!Array.isArray(record.hooks)) return [definition];
      const remaining = record.hooks.filter(
        (hook) =>
          !hook ||
          typeof hook !== "object" ||
          Array.isArray(hook) ||
          (hook as Record<string, unknown>).command !== command,
      );
      return remaining.length > 0 ? [{ ...record, hooks: remaining }] : [];
    });
    hooks[event] = install
      ? [
          ...cleaned,
          {
            ...(["PreToolUse", "PostToolUse", "PermissionRequest"].includes(event)
              ? { matcher: "*" }
              : {}),
            hooks: [{ type: "command", command, timeout: 5 }],
          },
        ]
      : cleaned;
  }
  writeJsonAtomic(target, { ...config, hooks });
}

interface HookListing {
  key: string;
  command: string;
  currentHash: string;
  trustStatus: string;
}

function collectHookListings(value: unknown): HookListing[] {
  const found: HookListing[] = [];
  const visit = (entry: unknown): void => {
    if (Array.isArray(entry)) {
      for (const child of entry) visit(child);
      return;
    }
    if (!entry || typeof entry !== "object") return;
    const record = entry as Record<string, unknown>;
    if (
      typeof record.key === "string" &&
      typeof record.command === "string" &&
      typeof record.currentHash === "string" &&
      typeof record.trustStatus === "string"
    ) {
      found.push(record as unknown as HookListing);
    }
    for (const child of Object.values(record)) visit(child);
  };
  visit(value);
  return found;
}
