import type { IncomingMessage, ServerResponse } from "node:http";
import { PairRequest } from "@acro/protocol";
import type { DeviceRegistry } from "./devices.ts";

export function createHttpHandler(registry: DeviceRegistry) {
  return async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const json = (status: number, body: unknown) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };

    if (req.method === "GET" && req.url === "/health") {
      json(200, { ok: true, name: "acro-runtime" });
      return;
    }

    if (req.method === "POST" && req.url === "/pair") {
      const chunks: Buffer[] = [];
      for await (const chunk of req) chunks.push(chunk as Buffer);
      let parsed;
      try {
        parsed = PairRequest.parse(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        json(400, { error: "invalid_request" });
        return;
      }
      const result = registry.pair(parsed.code, parsed.deviceName);
      if (!result) {
        // 抑制配对码暴力尝试
        await new Promise((r) => setTimeout(r, 500));
        json(403, { error: "invalid_code" });
        return;
      }
      json(200, { deviceId: result.device.id, token: result.token });
      return;
    }

    json(404, { error: "not_found" });
  };
}
