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
