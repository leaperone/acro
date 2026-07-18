import assert from "node:assert/strict";
import test from "node:test";
// @xterm 双包是 CJS,与 daemon.ts 同款 default import 再解构
import xtermHeadless from "@xterm/headless";

const { Terminal } = xtermHeadless;

// 守护标题采集的根基:daemon 靠 term.onTitleChange 从屏幕字节流提取 OSC 0/2 标题。
// 若升级 @xterm/headless 破坏了 OSC 标题解析,这里先红。
test("onTitleChange fires with OSC 0/2 titles from screen data", async () => {
  const term = new Terminal({ allowProposedApi: true });
  const titles: string[] = [];
  term.onTitleChange((t) => titles.push(t));
  await new Promise<void>((r) => term.write("\x1b]0;hello\x07", r)); // OSC 0 + BEL
  await new Promise<void>((r) => term.write("\x1b]2;world\x1b\\", r)); // OSC 2 + ST
  assert.deepEqual(titles, ["hello", "world"]);
});
