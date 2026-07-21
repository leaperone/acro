export interface ParsedCommandLine {
  command: string | undefined;
  args: string[];
  passthrough: string[] | null;
  serverRef: string | undefined;
}

export interface ParsedRunArgs {
  cwd: string | undefined;
  command: string | undefined;
}

export interface ParsedSshArgs {
  target: string;
  name: string | undefined;
  repo: string | undefined;
  branch: string | undefined;
  endpoint: string | undefined;
  pair: boolean;
}

function optionValue(args: string[], index: number, option: string): string {
  const value = args[index + 1];
  if (value === undefined || value.startsWith("--")) {
    throw new Error(`${option} requires a value`);
  }
  return value;
}

export function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

export function parseCommandLine(argv: string[]): ParsedCommandLine {
  const separator = argv.indexOf("--");
  const acroArgs = separator < 0 ? argv : argv.slice(0, separator);
  const passthrough = separator < 0 ? null : argv.slice(separator + 1);
  const kept: string[] = [];
  let serverRef: string | undefined;

  for (let i = 0; i < acroArgs.length; i += 1) {
    if (acroArgs[i] === "--server") {
      if (serverRef !== undefined) throw new Error("--server may only be specified once");
      serverRef = optionValue(acroArgs, i, "--server");
      i += 1;
    } else {
      kept.push(acroArgs[i]!);
    }
  }

  return {
    command: kept[0],
    args: kept.slice(1),
    passthrough,
    serverRef,
  };
}

export function parseRunArgs(args: string[], passthrough: string[] | null): ParsedRunArgs {
  const commandArgs: string[] = [];
  let cwd: string | undefined;

  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === "--cwd") {
      if (cwd !== undefined) throw new Error("--cwd may only be specified once");
      cwd = optionValue(args, i, "--cwd");
      i += 1;
    } else {
      commandArgs.push(args[i]!);
    }
  }
  const command = commandArgs.join(" ");
  const quotedPassthrough = passthrough?.map(shellQuote).join(" ") ?? "";

  return {
    cwd,
    command: [command, quotedPassthrough].filter(Boolean).join(" ") || undefined,
  };
}

export function parseSshArgs(args: string[]): ParsedSshArgs {
  let target: string | undefined;
  const opts: { name?: string; repo?: string; branch?: string; endpoint?: string } = {};
  let pair = false;
  for (let i = 0; i < args.length; i += 1) {
    const a = args[i]!;
    if (a === "--pair") {
      pair = true;
    } else if (a === "--name" || a === "--repo" || a === "--branch" || a === "--endpoint") {
      const key = a.slice(2) as "name" | "repo" | "branch" | "endpoint";
      if (opts[key] !== undefined) throw new Error(`${a} may only be specified once`);
      opts[key] = optionValue(args, i, a);
      i += 1;
    } else if (a.startsWith("--")) {
      throw new Error(`unknown ssh option: ${a}`);
    } else if (target !== undefined) {
      throw new Error("ssh accepts a single target");
    } else {
      target = a;
    }
  }
  if (!target) {
    throw new Error("usage: acro ssh <[user@]host|ssh-alias> [--pair] [--endpoint host:port]");
  }
  // 以 - 开头会被 ssh 当作选项(参数注入,如 -oProxyCommand=);目标不该长这样
  if (target.startsWith("-")) throw new Error(`invalid ssh target: ${target}`);
  return { target, name: opts.name, repo: opts.repo, branch: opts.branch, endpoint: opts.endpoint, pair };
}

function isLoopbackEndpoint(endpoint: string): boolean {
  const host = endpoint.replace(/:\d+$/, "").replace(/^\[|\]$/g, "");
  return host === "127.0.0.1" || host.startsWith("127.") || host === "localhost" || host === "::1";
}

// 从配对码入口里挑出"客户端可直连"的入口:剔除回环(只对服务器本机有意义),
// 显式 endpoint 置顶去重。用于 acro ssh --pair 决定连哪。
export function selectPairEndpoints(offerEndpoints: string[], endpoint?: string): string[] {
  const remote = offerEndpoints.filter((e) => !isLoopbackEndpoint(e));
  if (!endpoint) return remote;
  return [endpoint, ...remote.filter((e) => e !== endpoint)];
}

export function parsePairArgs(args: string[]): { name: string | undefined } {
  let name: string | undefined;
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === "--name") {
      if (name !== undefined) throw new Error("--name may only be specified once");
      name = optionValue(args, i, "--name");
      i += 1;
    } else if (args[i]!.startsWith("--")) {
      throw new Error(`unknown pair option: ${args[i]}`);
    } else {
      throw new Error("pairing offer must be provided on stdin");
    }
  }
  return { name };
}
