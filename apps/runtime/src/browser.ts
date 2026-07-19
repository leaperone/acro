// 服务端 Chromium:playwright-core + CDP screencast。
// 浏览器跑在 Mac mini 上,客户端只收 JPEG 帧、回传输入。
// ponytail: 浏览器活在 runtime 进程里,runtime 重启后由客户端重新 open;
// profile 持久化在 stateDir,登录态不丢。终端级的跨重启存活以后有需要再下沉 daemon。

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { EventEmitter } from "node:events";
import type { BrowserContext, CDPSession, Page } from "playwright-core";
import { paths } from "./paths.ts";

// 懒加载:打包形态(runtime.cjs)可能不带 playwright-core;
// 顶层 import 会让整个 runtime 启动即崩,浏览器能力必须只在使用时才要求依赖
async function loadChromium(): Promise<typeof import("playwright-core").chromium> {
  const mod = await import("playwright-core");
  return mod.chromium;
}

const DEFAULT_WIDTH = 1280;
const DEFAULT_HEIGHT = 800;
// 每个页面都可能持有 renderer；并发 open 也必须占用名额，不能靠竞态越过上限。
export const MAX_BROWSER_SURFACES = 32;

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
  castStarting: Promise<void> | null;
}

export class BrowserManager extends EventEmitter {
  private context: BrowserContext | null = null;
  private contextStarting: Promise<BrowserContext> | null = null;
  private surfaces = new Map<string, BrowserSurface>();
  private openingSurfaces = 0;
  private nextHandle = 1;

  private ensureContext(): Promise<BrowserContext> {
    if (this.context) return Promise.resolve(this.context);
    this.contextStarting ??= this.startContext().finally(() => {
      this.contextStarting = null;
    });
    return this.contextStarting;
  }

  private async startContext(): Promise<BrowserContext> {
    const chromium = await loadChromium();
    const context = await chromium.launchPersistentContext(path.join(paths.state, "browser-profile"), {
      executablePath: findChromium(),
      headless: process.env.ACRO_BROWSER_HEADLESS === "1",
      viewport: null,
    });
    this.context = context;
    context.on("close", () => {
      if (this.context === context) this.context = null;
      for (const surface of this.surfaces.values()) {
        this.emit("closed", surface.id, surface.handle);
      }
      this.surfaces.clear();
    });
    return context;
  }

  async open(opts: {
    url: string;
    width?: number | undefined;
    height?: number | undefined;
  }): Promise<string> {
    if (this.surfaces.size + this.openingSurfaces >= MAX_BROWSER_SURFACES) {
      throw new Error("browser surface limit reached");
    }
    this.openingSurfaces += 1;
    let page: Page | null = null;
    try {
      const context = await this.ensureContext();
      page = await context.newPage();
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
        castStarting: null,
      };
      this.surfaces.set(surface.id, surface);
      page.on("close", () => {
        this.surfaces.delete(surface.id);
        this.emit("closed", surface.id, surface.handle);
      });
      cdp.on("Page.screencastFrame", (frame: { data: string; sessionId: number }) => {
        surface.seq += 1;
        this.emit("frame", surface.handle, surface.seq, Buffer.from(frame.data, "base64"));
        void cdp.send("Page.screencastFrameAck", { sessionId: frame.sessionId }).catch(() => {});
      });
      await page.goto(opts.url).catch(() => {}); // 目标可能还没起,页面留在错误页即可
      if (!this.surfaces.has(surface.id)) {
        throw new Error("browser surface closed during open");
      }
      return surface.id;
    } catch (error) {
      await page?.close().catch(() => {});
      throw error;
    } finally {
      this.openingSurfaces -= 1;
    }
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
    if (!this.surfaces.has(browserId)) {
      throw new Error("browser surface closed during navigation");
    }
    return surface.page.url();
  }

  attachment(browserId: string): { channel: number; width: number; height: number } {
    const surface = this.get(browserId);
    return { channel: surface.handle, width: surface.width, height: surface.height };
  }

  async attach(browserId: string): Promise<void> {
    const surface = this.get(browserId);
    if (!surface.casting) {
      surface.castStarting ??= surface.cdp
        .send("Page.startScreencast", {
          format: "jpeg",
          quality: 65,
          maxWidth: surface.width,
          maxHeight: surface.height,
          everyNthFrame: 1,
        })
        .then(() => {
          surface.casting = true;
        })
        .finally(() => {
          surface.castStarting = null;
        });
      await surface.castStarting;
    }
  }

  async detach(browserId: string, shouldStop: () => boolean = () => true): Promise<void> {
    const surface = this.get(browserId);
    await surface.castStarting?.catch(() => {});
    if (!shouldStop()) return;
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
    const starting = this.contextStarting;
    const context = this.context ?? (starting ? await starting.catch(() => null) : null);
    await context?.close().catch(() => {});
    if (this.context === context) this.context = null;
  }
}
