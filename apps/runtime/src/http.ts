import type { IncomingMessage, ServerResponse } from "node:http";

// 配对不再走 HTTP(token 由配对码带外分发,认证在 E2EE 信道内),只剩健康检查。
export function createHttpHandler() {
  return (req: IncomingMessage, res: ServerResponse): void => {
    const json = (status: number, body: unknown) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };

    if (req.method === "GET" && req.url === "/health") {
      json(200, { ok: true, name: "acro-runtime" });
      return;
    }

    json(404, { error: "not_found" });
  };
}
