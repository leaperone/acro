import type { IncomingMessage, ServerResponse } from "node:http";

// 配对不再走 HTTP(token 由配对码带外分发,认证在 E2EE 信道内)。
// 只保留健康检查 + 仅限回环的本机再配对:桌面 App 静默接管本机 runtime 用。
// 信任边界与 0600 的 bootstrap-offer.txt 一致——同机同用户进程本就可读凭据。
export function createHttpHandler(mintLocalOffer?: () => string) {
  return (req: IncomingMessage, res: ServerResponse): void => {
    const json = (status: number, body: unknown) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };

    if (req.method === "GET" && req.url === "/health") {
      json(200, { ok: true, name: "acro-runtime" });
      return;
    }

    if (req.method === "POST" && req.url === "/local-offer" && mintLocalOffer) {
      const remote = req.socket.remoteAddress ?? "";
      const loopback = remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
      if (!loopback) {
        json(403, { error: "loopback_only" });
        return;
      }
      json(200, { offer: mintLocalOffer() });
      return;
    }

    json(404, { error: "not_found" });
  };
}
