// 服务端 Chromium:playwright-core + CDP screencast。
// 浏览器跑在 Mac mini 上,客户端只收 JPEG 帧、回传输入。
// ponytail: 浏览器活在 runtime 进程里,runtime 重启后由客户端重新 open;
// profile 持久化在 stateDir,登录态不丢。终端级的跨重启存活以后有需要再下沉 daemon。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { EventEmitter } from "node:events";
import { chromium, type BrowserContext, type CDPSession, type Page } from "playwright-core";
import { paths } from "./paths.ts";

const DEFAULT_WIDTH = 1280;
const DEFAULT_HEIGHT = 800;

function findChromium(): string {
  const cache = path.join(os.homedir(), "Library", "Caches", "ms-playwright");
  if (fs.existsSync(cache)) {
    for (const entry of fs.readdirSync(cache).sort().reverse()) {
      if (!entry.startsWith("chromium-")) continue;
      for (const rel of [
        "chrome-mac/Chromium.app/Contents/MacOS/Chromium",
        "chrome-mac-arm64/Chromium.app/Contents/MacOS/Chromium",
      ]) {
        const p = path.join(cache, entry, rel);
        if (fs.existsSync(p)) return p;
      }
    }
  }
  const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  if (fs.existsSync(chrome)) return chrome;
  throw new Error("no chromium found; run `npx playwright install chromium` or install Chrome");
}

interface BrowserSurface {
  id: string;
  handle: number;
  page: Page;
  cdp: CDPSession;
  width: number;
  height: number;
  seq: number;
  casting: boolean;
}

export class BrowserManager extends EventEmitter {
  private context: BrowserContext | null = null;
  private surfaces = new Map<string, BrowserSurface>();
  private nextHandle = 1;

  private async ensureContext(): Promise<BrowserContext> {
    if (this.context) return this.context;
    this.context = await chromium.launchPersistentContext(path.join(paths.state, "browser-profile"), {
      executablePath: findChromium(),
      headless: process.env.ACRO_BROWSER_HEADLESS === "1",
      viewport: null,
    });
    this.context.on("close", () => {
      this.context = null;
      this.surfaces.clear();
    });
    return this.context;
  }

  async open(opts: {
    url: string;
    width?: number | undefined;
    height?: number | undefined;
  }): Promise<string> {
    const context = await this.ensureContext();
    const page = await context.newPage();
    const width = opts.width ?? DEFAULT_WIDTH;
    const height = opts.height ?? DEFAULT_HEIGHT;
    await page.setViewportSize({ width, height });
    const cdp = await context.newCDPSession(page);
    const surface: BrowserSurface = {
      id: crypto.randomUUID(),
      handle: this.nextHandle++,
      page,
      cdp,
      width,
      height,
      seq: 0,
      casting: false,
    };
    this.surfaces.set(surface.id, surface);
    page.on("close", () => {
      this.surfaces.delete(surface.id);
      this.emit("closed", surface.id);
    });
    cdp.on("Page.screencastFrame", (frame: { data: string; sessionId: number }) => {
      surface.seq += 1;
      this.emit("frame", surface.handle, surface.seq, Buffer.from(frame.data, "base64"));
      void cdp.send("Page.screencastFrameAck", { sessionId: frame.sessionId }).catch(() => {});
    });
    await page.goto(opts.url).catch(() => {}); // 目标可能还没起,页面留在错误页即可
    return surface.id;
  }

  private get(browserId: string): BrowserSurface {
    const surface = this.surfaces.get(browserId);
    if (!surface) throw new Error("browser surface not found");
    return surface;
  }

  list(): Array<{ browserId: string; url: string; title: string }> {
    return [...this.surfaces.values()].map((s) => ({
      browserId: s.id,
      url: s.page.url(),
      title: "", // page.title() 是异步的,列表里不阻塞;客户端要标题走事件
    }));
  }

  async navigate(browserId: string, url: string): Promise<string> {
    const surface = this.get(browserId);
    await surface.page.goto(url).catch(() => {});
    return surface.page.url();
  }

  async attach(browserId: string): Promise<{ channel: number; width: number; height: number }> {
    const surface = this.get(browserId);
    if (!surface.casting) {
      surface.casting = true;
      await surface.cdp.send("Page.startScreencast", {
        format: "jpeg",
        quality: 65,
        maxWidth: surface.width,
        maxHeight: surface.height,
        everyNthFrame: 1,
      });
    }
    return { channel: surface.handle, width: surface.width, height: surface.height };
  }

  async detach(browserId: string): Promise<void> {
    const surface = this.get(browserId);
    if (surface.casting) {
      surface.casting = false;
      await surface.cdp.send("Page.stopScreencast").catch(() => {});
    }
  }

  async input(
    browserId: string,
    event:
      | { kind: "click"; x: number; y: number }
      | { kind: "move"; x: number; y: number }
      | { kind: "wheel"; x: number; y: number; deltaY: number }
      | { kind: "key"; key: string }
      | { kind: "type"; text: string },
  ): Promise<void> {
    const { page } = this.get(browserId);
    switch (event.kind) {
      case "click":
        await page.mouse.click(event.x, event.y);
        break;
      case "move":
        await page.mouse.move(event.x, event.y);
        break;
      case "wheel":
        await page.mouse.move(event.x, event.y);
        await page.mouse.wheel(0, event.deltaY);
        break;
      case "key":
        await page.keyboard.press(event.key);
        break;
      case "type":
        await page.keyboard.type(event.text);
        break;
    }
  }

  async close(browserId: string): Promise<void> {
    const surface = this.get(browserId);
    await surface.page.close().catch(() => {});
    this.surfaces.delete(browserId);
  }

  async shutdown(): Promise<void> {
    await this.context?.close().catch(() => {});
    this.context = null;
  }
}
