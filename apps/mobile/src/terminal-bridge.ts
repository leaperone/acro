export const TERMINAL_DOCUMENT_ORIGIN = "https://terminal.acro.invalid";
export const TERMINAL_DOCUMENT_URL = `${TERMINAL_DOCUMENT_ORIGIN}/`;

export type TerminalBridgeMessage =
  | { type: "ready"; cols: number; rows: number }
  | { type: "input"; dataB64: string }
  | { type: "open"; url: string }
  | { type: "resize"; cols: number; rows: number };

export function isTerminalDocumentUrl(url: string): boolean {
  return (
    url === "about:blank" ||
    url === TERMINAL_DOCUMENT_ORIGIN ||
    url === TERMINAL_DOCUMENT_URL
  );
}

export function safeTerminalExternalUrl(raw: string): string | null {
  try {
    const url = new URL(raw);
    return url.protocol === "http:" || url.protocol === "https:" ? url.href : null;
  } catch {
    return null;
  }
}

function validSize(value: unknown): value is number {
  return Number.isInteger(value) && (value as number) >= 2 && (value as number) <= 1000;
}

function validBase64(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length % 4 === 0 &&
    /^[A-Za-z0-9+/]*={0,2}$/.test(value)
  );
}

export function parseTerminalBridgeMessage(
  raw: string,
  documentUrl: string,
  expectedBridgeToken: string,
): TerminalBridgeMessage | null {
  if (!isTerminalDocumentUrl(documentUrl)) return null;
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!value || typeof value !== "object") return null;
  const message = value as Record<string, unknown>;
  if (message.bridgeToken !== expectedBridgeToken) return null;
  if (message.type === "input" && validBase64(message.dataB64)) {
    return { type: "input", dataB64: message.dataB64 };
  }
  if (message.type === "open" && typeof message.url === "string") {
    const url = safeTerminalExternalUrl(message.url);
    return url ? { type: "open", url } : null;
  }
  if (
    (message.type === "ready" || message.type === "resize") &&
    validSize(message.cols) &&
    validSize(message.rows)
  ) {
    return { type: message.type, cols: message.cols, rows: message.rows };
  }
  return null;
}
