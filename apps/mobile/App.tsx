import { useCallback, useEffect, useRef, useState } from "react";
import {
  ActivityIndicator,
  AppState,
  FlatList,
  Image,
  Linking,
  Pressable,
  SafeAreaView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { StatusBar } from "expo-status-bar";
import * as SecureStore from "expo-secure-store";
import { WebView } from "react-native-webview";
import type { Session, Workspace } from "@acro/protocol";
import { encodeInFrame, FRAME_BROWSER, FRAME_OUT, FRAME_SIM } from "@acro/protocol";
import {
  MobileClient,
  pairWithOffer,
  parseServerConfig,
  type ServerConfig,
} from "./src/client.ts";
import { mapContainedPoint } from "./src/surface.ts";
import {
  isTerminalDocumentUrl,
  parseTerminalBridgeMessage,
  safeTerminalExternalUrl,
  TERMINAL_DOCUMENT_URL,
} from "./src/terminal-bridge.ts";
import { createTerminalHtml } from "./src/terminal-html.ts";

// ---- 小工具 ----

function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  const chunk = 8192;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function concatBytes(chunks: Uint8Array[]): Uint8Array {
  if (chunks.length === 1) return chunks[0]!;
  let total = 0;
  for (const c of chunks) total += c.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.length;
  }
  return out;
}

type Route =
  | { name: "home" }
  | { name: "terminal"; session: Session }
  | { name: "surface"; kind: "browser" | "sim"; refId: string; title: string };

// ---- 根组件 ----

export default function App() {
  const [config, setConfig] = useState<ServerConfig | null | undefined>(undefined);
  const [client, setClient] = useState<MobileClient | null>(null);
  const [connected, setConnected] = useState(false);
  const [route, setRoute] = useState<Route>({ name: "home" });

  useEffect(() => {
    void (async () => {
      try {
        const raw = await SecureStore.getItemAsync("acro.config");
        const parsed = parseServerConfig(raw);
        if (raw && !parsed) void SecureStore.deleteItemAsync("acro.config").catch(() => {});
        setConfig(parsed);
      } catch {
        setConfig(null);
      }
    })();
  }, []);

  useEffect(() => {
    if (!config) return;
    setConnected(false);
    const c = new MobileClient(config);
    const unsubscribeState = c.subscribeState(setConnected);
    void c.connect().catch(() => {});
    setClient(c);
    return () => {
      unsubscribeState();
      c.close();
    };
  }, [config]);

  const onPaired = useCallback(async (offer: string) => {
    const cfg = await pairWithOffer(offer, "iPhone");
    await SecureStore.setItemAsync("acro.config", JSON.stringify(cfg));
    setConfig(cfg);
  }, []);

  if (config === undefined) {
    return (
      <SafeAreaView style={styles.root}>
        <ActivityIndicator />
      </SafeAreaView>
    );
  }
  if (!config) return <PairScreen onPaired={onPaired} />;
  if (!client || !connected) {
    return (
      <SafeAreaView style={styles.root}>
        <StatusBar style="light" />
        <View style={styles.center}>
          <ActivityIndicator />
          <Text style={styles.dim}>连接 {config.name} …</Text>
          <Pressable
            style={styles.buttonGhost}
            onPress={() => {
              void SecureStore.deleteItemAsync("acro.config");
              client?.close();
              setConnected(false);
              setClient(null);
              setConfig(null);
            }}
          >
            <Text style={styles.buttonGhostText}>重新配对</Text>
          </Pressable>
        </View>
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={styles.root}>
      <StatusBar style="light" />
      {route.name === "home" && (
        <HomeScreen client={client} onOpen={setRoute} />
      )}
      {route.name === "terminal" && (
        <TerminalScreen
          client={client}
          session={route.session}
          onBack={() => setRoute({ name: "home" })}
        />
      )}
      {route.name === "surface" && (
        <SurfaceScreen
          client={client}
          kind={route.kind}
          refId={route.refId}
          title={route.title}
          onBack={() => setRoute({ name: "home" })}
        />
      )}
    </SafeAreaView>
  );
}

// ---- 配对 ----

function PairScreen({ onPaired }: { onPaired: (offer: string) => Promise<void> }) {
  const [offer, setOffer] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  return (
    <SafeAreaView style={styles.root}>
      <StatusBar style="light" />
      <View style={styles.pairBox}>
        <Text style={styles.title}>Acro</Text>
        <TextInput
          style={[styles.input, styles.offerInput]}
          placeholder="粘贴配对码 (acro://pair?c=…)"
          placeholderTextColor="#666"
          autoCapitalize="none"
          autoCorrect={false}
          multiline
          value={offer}
          onChangeText={setOffer}
        />
        {error ? <Text style={styles.error}>{error}</Text> : null}
        <Pressable
          style={styles.button}
          disabled={busy}
          onPress={() => {
            setBusy(true);
            setError("");
            onPaired(offer.trim()).catch((e: Error) => {
              setError(e.message);
              setBusy(false);
            });
          }}
        >
          <Text style={styles.buttonText}>{busy ? "配对中…" : "配对"}</Text>
        </Pressable>
      </View>
    </SafeAreaView>
  );
}

// ---- 主页:项目 / 会话 / 模拟器 ----

interface SimInfo {
  udid: string;
  name: string;
  state: string;
  runtime: string;
}

type HomeItem =
  | { kind: "workspace"; workspace: Workspace }
  | { kind: "session"; session: Session; workspace: Workspace | null }
  | { kind: "section"; id: string; title: string };

function sessionStatusLabel(session: Session): string {
  const agent = session.agent;
  if (!agent) return session.alive ? "attach" : `exit ${session.exitCode ?? "?"}`;
  if (agent.interrupted) {
    return agent.managed && agent.providerSessionId ? "可恢复" : "已中断";
  }
  const status = {
    starting: "启动中",
    working: "工作中",
    waiting: "等待输入",
    done: session.alive ? "等待指令" : agent.managed && agent.providerSessionId ? "可恢复" : "已结束",
    error: session.alive ? "异常" : agent.managed && agent.providerSessionId ? "可恢复" : "异常",
  }[agent.state];
  return session.alive && !agent.managed ? `${status} · 不可恢复` : status;
}

function HomeScreen({
  client,
  onOpen,
}: {
  client: MobileClient;
  onOpen: (route: Route) => void;
}) {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [workspaces, setWorkspaces] = useState<Workspace[]>([]);
  const [sims, setSims] = useState<SimInfo[]>([]);
  const [agentProviders, setAgentProviders] = useState<Array<"codex" | "claude">>([]);
  const [agentCapability, setAgentCapability] = useState<"loading" | "ready" | "unsupported" | "unavailable">("loading");
  const [error, setError] = useState("");
  const [creatingWorkspace, setCreatingWorkspace] = useState(false);
  const [resumingSessionId, setResumingSessionId] = useState<string | null>(null);

  const refreshSessions = useCallback(async () => {
    try {
      const [nextSessions, nextWorkspaces] = await Promise.all([
        client.rpc("session.list", {}),
        client.rpc("workspace.list", {}),
      ]);
      setSessions(nextSessions);
      setWorkspaces(nextWorkspaces);
      setError("");
    } catch (reason) {
      setError(`刷新失败：${reason instanceof Error ? reason.message : String(reason)}`);
    }
  }, [client]);

  const refreshAgentProviders = useCallback(async () => {
    try {
      const { providers } = await client.rpc("agent.capabilities", {});
      setAgentProviders(providers);
      setAgentCapability(providers.length > 0 ? "ready" : "unavailable");
    } catch (reason) {
      setAgentProviders([]);
      const message = reason instanceof Error ? reason.message : String(reason);
      setAgentCapability(message.includes("unknown_method") ? "unsupported" : "unavailable");
    }
  }, [client]);

  const refreshSimulators = useCallback(() => {
    void client.rpc("simulator.list", {}).then(setSims).catch(() => {});
  }, [client]);

  useEffect(() => {
    void refreshSessions();
    refreshSimulators();
    void refreshAgentProviders();
    const unsubscribeEvent = client.subscribeEvent((event) => {
      if (
        event === "session.created" ||
        event === "session.exit" ||
        event === "session.removed" ||
        event === "session.agentChanged" ||
        event === "session.title"
      ) {
        void refreshSessions();
      }
    });
    const appState = AppState.addEventListener("change", (state) => {
      if (state === "active") {
        void refreshSessions();
        void refreshAgentProviders();
      }
    });
    return () => {
      unsubscribeEvent();
      appState.remove();
    };
  }, [client, refreshSessions, refreshSimulators, refreshAgentProviders]);

  const createSession = (workspace: Workspace) => {
    setError("");
    void (async () => {
      const inheritCwdFrom = workspace.sessionIds.find((id) =>
        sessions.some((session) => session.id === id && session.alive),
      );
      const session = await client.rpc("session.create", {
        workspaceId: workspace.id,
        ...(inheritCwdFrom ? { inheritCwdFrom } : {}),
        cols: 80,
        rows: 24,
      });
      onOpen({ name: "terminal", session });
    })().catch((reason) => setError(reason instanceof Error ? reason.message : String(reason)));
  };

  const createAgent = (
    source: Session,
    workspace: Workspace | null,
    agent: "codex" | "claude",
  ) => {
    setError("");
    void (async () => {
      if (!source.alive) throw new Error("来源终端已经结束");
      if (!agentProviders.includes(agent)) throw new Error("请先升级 Mac 上的 Acro Runtime");
      const session = await client.rpc("session.create", {
        ...(workspace ? { workspaceId: workspace.id } : {}),
        inheritCwdFrom: source.id,
        agent,
        cols: 80,
        rows: 24,
      });
      onOpen({ name: "terminal", session });
    })().catch((reason) => setError(reason instanceof Error ? reason.message : String(reason)));
  };

  const createFirstWorkspace = () => {
    setCreatingWorkspace(true);
    setError("");
    void (async () => {
      const workspace = await client.rpc("workspace.create", {});
      setWorkspaces((current) =>
        current.some((candidate) => candidate.id === workspace.id)
          ? current
          : [...current, workspace],
      );
      const session = await client.rpc("session.create", {
        workspaceId: workspace.id,
        cols: 80,
        rows: 24,
      });
      onOpen({ name: "terminal", session });
    })()
      .catch((reason) => {
        setError(reason instanceof Error ? reason.message : String(reason));
        void refreshSessions();
      })
      .finally(() => setCreatingWorkspace(false));
  };

  const openSession = (session: Session) => {
    if (session.alive) {
      onOpen({ name: "terminal", session });
      return;
    }
    if (!session.agent?.managed || !session.agent.providerSessionId) return;
    setError("");
    setResumingSessionId(session.id);
    void client
      .rpc("session.resumeAgent", { sessionId: session.id })
      .then((resumed) => onOpen({ name: "terminal", session: resumed }))
      .catch((reason) => setError(reason instanceof Error ? reason.message : String(reason)))
      .finally(() => setResumingSessionId(null));
  };

  const assignedSessionIds = new Set(workspaces.flatMap((workspace) => workspace.sessionIds));
  const items: HomeItem[] = workspaces.flatMap((workspace) => [
    { kind: "workspace" as const, workspace },
    ...workspace.sessionIds.flatMap((sessionId) => {
      const session = sessions.find((candidate) => candidate.id === sessionId);
      return session ? [{ kind: "session" as const, session, workspace }] : [];
    }),
  ]);
  const orphanSessions = sessions.filter((session) => !assignedSessionIds.has(session.id));
  if (orphanSessions.length > 0) {
    items.push(
      { kind: "section", id: "other-sessions", title: "其他会话" },
      ...orphanSessions.map((session) => ({ kind: "session" as const, session, workspace: null })),
    );
  }

  return (
    <View style={styles.flex}>
      <Text style={styles.header}>Acro</Text>
      {error ? (
        <View style={styles.homeNotice}>
          <Text style={styles.error}>{error}</Text>
          <Pressable
            onPress={() => {
              void refreshSessions();
              void refreshAgentProviders();
            }}
          >
            <Text style={styles.buttonGhostText}>重试</Text>
          </Pressable>
        </View>
      ) : null}
      {agentCapability === "unsupported" ? (
        <Text style={styles.capabilityNotice}>请升级 Mac 上的 Acro Runtime，才能管理 Agent。</Text>
      ) : agentCapability === "unavailable" ? (
        <Text style={styles.capabilityNotice}>Mac 当前无法管理 Agent，请检查终端服务和 CLI。</Text>
      ) : null}
      <FlatList
        data={items}
        keyExtractor={(item) =>
          item.kind === "workspace"
            ? `workspace-${item.workspace.id}`
            : item.kind === "session"
              ? `session-${item.session.id}`
              : item.id
        }
        ListHeaderComponent={
          <View>
            {workspaces.length === 0 ? (
              <Pressable
                style={styles.row}
                disabled={creatingWorkspace}
                onPress={createFirstWorkspace}
              >
                <Text style={styles.rowText}>
                  {creatingWorkspace ? "正在创建…" : "创建 Workspace"}
                </Text>
                <Text style={styles.dim}>开始</Text>
              </Pressable>
            ) : null}
          </View>
        }
        renderItem={({ item }) => {
          if (item.kind === "section") {
            return <Text style={styles.section}>{item.title}</Text>;
          }
          if (item.kind === "workspace") {
            const workspace = item.workspace;
            return (
              <View>
                <Text style={styles.section}>{workspace.name}</Text>
                <Pressable style={styles.row} onPress={() => createSession(workspace)}>
                  <Text style={styles.rowText}>新建终端</Text>
                  <Text style={styles.dim}>打开</Text>
                </Pressable>
              </View>
            );
          }
          const s = item.session;
          const canResume = !s.alive && Boolean(s.agent?.managed && s.agent.providerSessionId);
          const disabled = !s.alive && !canResume;
          return (
            <View>
              <Pressable
                style={[styles.row, disabled && styles.disabledRow]}
                disabled={disabled || resumingSessionId === s.id}
                onPress={() => openSession(s)}
              >
                <Text style={[styles.rowText, !s.alive && styles.dead]} numberOfLines={1}>
                  {s.title?.trim() ||
                    (s.agent ? (s.agent.provider === "codex" ? "Codex" : "Claude") : s.command)}
                </Text>
                <Text style={styles.dim}>
                  {resumingSessionId === s.id
                    ? "恢复中…"
                    : sessionStatusLabel(s)}
                </Text>
              </Pressable>
              {s.alive && item.workspace && agentProviders.length > 0 ? (
                <View style={styles.agentActions}>
                  <Text style={styles.dim}>从此目录启动</Text>
                  {agentProviders.map((provider) => (
                    <Pressable
                      key={provider}
                      style={styles.agentAction}
                      onPress={() => createAgent(s, item.workspace, provider)}
                    >
                      <Text style={styles.buttonGhostText}>
                        {provider === "codex" ? "Codex" : "Claude"}
                      </Text>
                    </Pressable>
                  ))}
                </View>
              ) : null}
            </View>
          );
        }}
        ListFooterComponent={
          <View>
            <Text style={styles.section}>模拟器</Text>
            {sims.map((d) => (
              <Pressable
                key={d.udid}
                style={styles.row}
                onPress={() => {
                  if (d.state === "Booted") {
                    onOpen({ name: "surface", kind: "sim", refId: d.udid, title: d.name });
                  } else {
                    void client
                      .rpc("simulator.boot", { udid: d.udid })
                      .then(() =>
                        onOpen({ name: "surface", kind: "sim", refId: d.udid, title: d.name }),
                      )
                      .catch(() => {});
                  }
                }}
              >
                <Text style={styles.rowText}>{d.name}</Text>
                <Text style={styles.dim}>{d.state}</Text>
              </Pressable>
            ))}
          </View>
        }
      />
    </View>
  );
}

// ---- 终端 ----

const ACCESSORY_KEYS: Array<{ label: string; bytes: string }> = [
  { label: "Esc", bytes: "\x1b" },
  { label: "Tab", bytes: "\t" },
  { label: "^C", bytes: "\x03" },
  { label: "^D", bytes: "\x04" },
  { label: "↑", bytes: "\x1b[A" },
  { label: "↓", bytes: "\x1b[B" },
  { label: "←", bytes: "\x1b[D" },
  { label: "→", bytes: "\x1b[C" },
];

function TerminalScreen({
  client,
  session,
  onBack,
}: {
  client: MobileClient;
  session: Session;
  onBack: () => void;
}) {
  const webRef = useRef<WebView>(null);
  const channelRef = useRef<number | null>(null);
  const terminalDocumentActiveRef = useRef(true);
  const terminalSizeRef = useRef({ cols: 80, rows: 24 });
  // 合帧缓冲提到组件级:attach(含 WebView 重载后的重挂)要能丢弃清屏前残留的旧帧,
  // 否则它们会在下个 rAF 被 flush 到新 snapshot 之后,污染画面。
  const pendingFramesRef = useRef<Uint8Array[]>([]);
  const frameRafRef = useRef<number | null>(null);
  const [bridgeToken] = useState(() =>
    bytesToB64(globalThis.crypto.getRandomValues(new Uint8Array(32))),
  );
  const bridgeExpression = `window[${JSON.stringify(`__acro_${bridgeToken}`)}]`;
  const [terminalSource] = useState(() => ({
    html: createTerminalHtml(bridgeToken),
    baseUrl: TERMINAL_DOCUMENT_URL,
  }));
  // 终端占用锁:被其他设备占用时显示遮罩,显式接管才恢复输入
  const [occupant, setOccupant] = useState<string | null>(null);
  const [attachError, setAttachError] = useState("");

  const inject = useCallback((js: string) => {
    if (terminalDocumentActiveRef.current) {
      webRef.current?.injectJavaScript(`${js}; true;`);
    }
  }, []);

  const attach = useCallback(
    async (cols: number, rows: number) => {
      setAttachError("");
      const res = await client.rpc("session.attach", { sessionId: session.id });
      // 清屏前先丢弃残留的旧帧并取消挂起的 flush,避免旧字节落到新 snapshot 之后
      pendingFramesRef.current = [];
      if (frameRafRef.current !== null) {
        cancelAnimationFrame(frameRafRef.current);
        frameRafRef.current = null;
      }
      channelRef.current = res.channel;
      inject(`${bridgeExpression}?.clear()`);
      inject(`${bridgeExpression}?.write(${JSON.stringify(res.snapshot)})`);
      if (cols !== res.cols || rows !== res.rows) {
        await client.rpc("session.resize", { sessionId: session.id, cols, rows });
      }
    },
    [bridgeExpression, client, session.id, inject],
  );

  const claimFocus = useCallback(
    async (force: boolean) => {
      const { claimed } = await client.rpc("session.claimFocus", {
        sessionId: session.id,
        ...(force ? { force: true } : {}),
      });
      if (claimed) {
        setOccupant(null);
        return;
      }
      setOccupant("其他设备");
      const owners = await client.rpc("session.focusList", {});
      const owner = owners.find((entry) => entry.sessionId === session.id);
      setOccupant(
        owner && owner.deviceId !== client.deviceId ? owner.deviceName || "其他设备" : null,
      );
    },
    [client, session.id],
  );

  useEffect(() => {
    // 合帧:PTY 刷屏时每秒可上百个小 OUT 帧,逐帧跨桥 injectJavaScript 会堆积。
    // 一个 rAF 窗口内的帧拼成一次 write:跨桥次数和 base64 次数都压到每帧渲染一次。
    const flushFrames = () => {
      frameRafRef.current = null;
      const pending = pendingFramesRef.current;
      if (pending.length === 0) return;
      pendingFramesRef.current = [];
      inject(`${bridgeExpression}?.write("${bytesToB64(concatBytes(pending))}")`);
    };
    const unsubscribeFrame = client.subscribeFrame((frame) => {
      if (frame.type === FRAME_OUT && frame.channel === channelRef.current) {
        pendingFramesRef.current.push(frame.data);
        if (frameRafRef.current === null) frameRafRef.current = requestAnimationFrame(flushFrames);
      }
    });
    // 占用变化实时反映:他人接管 → 遮罩;释放/自己 → 解除
    const unsubscribeEvent = client.subscribeEvent((event, payload) => {
      if (event !== "session.focusChanged") return;
      const p = payload as { sessionId: string; deviceId: string | null; deviceName: string | null };
      if (p.sessionId !== session.id) return;
      setOccupant(
        p.deviceId && p.deviceId !== client.deviceId ? p.deviceName || "其他设备" : null,
      );
    });
    // 打开即认领:无主则静默拿下;被占用则先遮罩,等用户显式接管
    void claimFocus(false).catch(() => {});
    return () => {
      if (frameRafRef.current !== null) {
        cancelAnimationFrame(frameRafRef.current);
        frameRafRef.current = null;
      }
      pendingFramesRef.current = [];
      unsubscribeFrame();
      unsubscribeEvent();
      void client.rpc("session.detach", { sessionId: session.id }).catch(() => {});
    };
  }, [bridgeExpression, client, session.id, claimFocus, inject]);

  const takeOver = () => {
    void claimFocus(true).catch(() => {});
  };

  const openExternalUrl = useCallback((raw: string) => {
    const url = safeTerminalExternalUrl(raw);
    if (url) void Linking.openURL(url).catch(() => {});
  }, []);

  const sendBytes = (text: string) => {
    const channel = channelRef.current;
    if (channel === null) return;
    client.sendBinary(encodeInFrame(channel, b64ToBytes(btoa(text))));
  };

  return (
    <View style={styles.flex}>
      <View style={styles.bar}>
        <Pressable onPress={onBack}>
          <Text style={styles.barAction}>‹ 返回</Text>
        </Pressable>
        <Text style={styles.barTitle} numberOfLines={1}>
          {session.command}
        </Text>
      </View>
      {attachError ? (
        <View style={styles.terminalError}>
          <Text style={styles.error}>{attachError}</Text>
          <Pressable
            onPress={() => {
              const { cols, rows } = terminalSizeRef.current;
              void attach(cols, rows).catch((reason) =>
                setAttachError(reason instanceof Error ? reason.message : String(reason)),
              );
            }}
          >
            <Text style={styles.buttonGhostText}>重试连接</Text>
          </Pressable>
        </View>
      ) : null}
      <WebView
        ref={webRef}
        source={terminalSource}
        style={styles.flex}
        originWhitelist={["*"]}
        keyboardDisplayRequiresUserAction={false}
        onShouldStartLoadWithRequest={(request) => {
          if (isTerminalDocumentUrl(request.url)) return true;
          openExternalUrl(request.url);
          return false;
        }}
        onOpenWindow={(event) => openExternalUrl(event.nativeEvent.targetUrl)}
        onLoadStart={(event) => {
          terminalDocumentActiveRef.current = isTerminalDocumentUrl(event.nativeEvent.url);
        }}
        onMessage={(ev) => {
          const msg = parseTerminalBridgeMessage(
            ev.nativeEvent.data,
            ev.nativeEvent.url,
            bridgeToken,
          );
          if (!msg) return;
          if (msg.type === "ready") {
            terminalSizeRef.current = { cols: msg.cols, rows: msg.rows };
            void attach(msg.cols, msg.rows).catch((reason) =>
              setAttachError(reason instanceof Error ? reason.message : String(reason)),
            );
          } else if (msg.type === "input") {
            const channel = channelRef.current;
            if (channel !== null) client.sendBinary(encodeInFrame(channel, b64ToBytes(msg.dataB64)));
          } else if (msg.type === "open") {
            openExternalUrl(msg.url);
          } else if (msg.type === "resize") {
            void client
              .rpc("session.resize", { sessionId: session.id, cols: msg.cols, rows: msg.rows })
              .catch(() => {});
          }
        }}
      />
      <View style={styles.accessory}>
        {ACCESSORY_KEYS.map((k) => (
          <Pressable key={k.label} style={styles.key} onPress={() => sendBytes(k.bytes)}>
            <Text style={styles.keyText}>{k.label}</Text>
          </Pressable>
        ))}
      </View>
      {occupant !== null && (
        <View style={styles.focusMask}>
          <Text style={styles.focusTitle}>此终端正在被「{occupant}」使用</Text>
          <Text style={styles.focusHint}>接管后这里恢复操作,对方会被暂停</Text>
          <Pressable style={styles.focusButton} onPress={takeOver}>
            <Text style={styles.focusButtonText}>在此设备继续使用</Text>
          </Pressable>
        </View>
      )}
    </View>
  );
}

// ---- 画面(浏览器 / 模拟器) ----

function SurfaceScreen({
  client,
  kind,
  refId,
  title,
  onBack,
}: {
  client: MobileClient;
  kind: "browser" | "sim";
  refId: string;
  title: string;
  onBack: () => void;
}) {
  const [frameUri, setFrameUri] = useState<string | null>(null);
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  const channelRef = useRef<number | null>(null);
  const layoutRef = useRef<{ w: number; h: number }>({ w: 1, h: 1 });

  useEffect(() => {
    // 丢帧只渲染最新:base64 + setState + 原生图像解码远慢于截流帧率,
    // 逐帧渲染只会让延迟单调堆积。一个 rAF 窗口内只保留并渲染最后一帧。
    let latest: { mime: string; data: Uint8Array } | null = null;
    let rafId: number | null = null;
    const flushFrame = () => {
      rafId = null;
      if (!latest) return;
      const { mime, data } = latest;
      latest = null;
      setFrameUri(`data:${mime};base64,${bytesToB64(data)}`);
    };
    const unsubscribeFrame = client.subscribeFrame((frame) => {
      if (
        (frame.type === FRAME_BROWSER || frame.type === FRAME_SIM) &&
        frame.channel === channelRef.current
      ) {
        latest = {
          mime: frame.type === FRAME_BROWSER ? "image/jpeg" : "image/png",
          data: frame.data,
        };
        if (rafId === null) rafId = requestAnimationFrame(flushFrame);
      }
    });
    void (async () => {
      if (kind === "browser") {
        const res = await client.rpc("browser.attach", { browserId: refId });
        channelRef.current = res.channel;
        setSize({ w: res.width, h: res.height });
      } else {
        const res = await client.rpc("simulator.attach", { udid: refId });
        channelRef.current = res.channel;
      }
    })().catch(() => {});
    return () => {
      if (rafId !== null) cancelAnimationFrame(rafId);
      unsubscribeFrame();
      if (kind === "browser") {
        void client.rpc("browser.detach", { browserId: refId }).catch(() => {});
      } else {
        void client.rpc("simulator.detach", { udid: refId }).catch(() => {});
      }
    };
  }, [client, kind, refId]);

  return (
    <View style={styles.flex}>
      <View style={styles.bar}>
        <Pressable onPress={onBack}>
          <Text style={styles.barAction}>‹ 返回</Text>
        </Pressable>
        <Text style={styles.barTitle}>{title}</Text>
      </View>
      <Pressable
        style={styles.flex}
        onLayout={(e) => {
          layoutRef.current = {
            w: e.nativeEvent.layout.width,
            h: e.nativeEvent.layout.height,
          };
        }}
        onPress={(e) => {
          if (kind !== "browser" || !size) return;
          const point = mapContainedPoint(
            { x: e.nativeEvent.locationX, y: e.nativeEvent.locationY },
            layoutRef.current,
            size,
          );
          if (!point) return;
          void client
            .rpc("browser.input", {
              browserId: refId,
              event: {
                kind: "click",
                x: point.x,
                y: point.y,
              },
            })
            .catch(() => {});
        }}
      >
        {frameUri ? (
          <Image source={{ uri: frameUri }} style={styles.flex} resizeMode="contain" />
        ) : (
          <View style={styles.center}>
            <ActivityIndicator />
            <Text style={styles.dim}>等待画面…</Text>
          </View>
        )}
      </Pressable>
    </View>
  );
}

// ---- 样式 ----

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: "#11111b" },
  flex: { flex: 1 },
  center: { flex: 1, alignItems: "center", justifyContent: "center", gap: 12 },
  title: { fontSize: 32, fontWeight: "700", color: "#cdd6f4", textAlign: "center" },
  header: {
    fontSize: 20,
    fontWeight: "700",
    color: "#cdd6f4",
    paddingHorizontal: 16,
    paddingVertical: 8,
  },
  section: {
    fontSize: 13,
    fontWeight: "600",
    color: "#89b4fa",
    paddingHorizontal: 16,
    paddingTop: 16,
    paddingBottom: 4,
    textTransform: "uppercase",
  },
  row: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#313244",
  },
  rowText: { color: "#cdd6f4", fontSize: 15, flexShrink: 1 },
  dead: { color: "#585b70" },
  disabledRow: { opacity: 0.55 },
  dim: { color: "#7f849c", fontSize: 13 },
  sub: { backgroundColor: "#181825" },
  homeNotice: { paddingHorizontal: 16, paddingVertical: 8, gap: 6 },
  capabilityNotice: { color: "#f9e2af", paddingHorizontal: 16, paddingVertical: 6 },
  agentActions: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "flex-end",
    gap: 12,
    paddingHorizontal: 16,
    paddingBottom: 8,
    backgroundColor: "#181825",
  },
  agentAction: { paddingVertical: 4, paddingHorizontal: 6 },
  pairBox: { flex: 1, justifyContent: "center", padding: 24, gap: 12 },
  input: {
    backgroundColor: "#1e1e2e",
    color: "#cdd6f4",
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 15,
  },
  offerInput: { minHeight: 96, textAlignVertical: "top" },
  error: { color: "#f38ba8" },
  button: {
    backgroundColor: "#89b4fa",
    borderRadius: 8,
    paddingVertical: 12,
    alignItems: "center",
  },
  buttonText: { color: "#11111b", fontWeight: "600" },
  buttonGhost: { padding: 8 },
  buttonGhostText: { color: "#89b4fa" },
  bar: {
    flexDirection: "row",
    alignItems: "center",
    gap: 12,
    paddingHorizontal: 16,
    paddingVertical: 10,
    backgroundColor: "#181825",
  },
  barAction: { color: "#89b4fa", fontSize: 16 },
  barTitle: { color: "#cdd6f4", fontSize: 15, fontWeight: "600", flexShrink: 1 },
  terminalError: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 12,
    paddingHorizontal: 16,
    paddingVertical: 8,
    backgroundColor: "#181825",
  },
  accessory: {
    flexDirection: "row",
    backgroundColor: "#181825",
    paddingVertical: 6,
    paddingHorizontal: 8,
    gap: 6,
  },
  key: {
    backgroundColor: "#313244",
    borderRadius: 6,
    paddingVertical: 8,
    paddingHorizontal: 12,
  },
  keyText: { color: "#cdd6f4", fontSize: 13 },
  focusMask: {
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: "rgba(17, 17, 27, 0.92)",
    alignItems: "center",
    justifyContent: "center",
    gap: 10,
    padding: 24,
  },
  focusTitle: { color: "#cdd6f4", fontSize: 16, fontWeight: "600" },
  focusHint: { color: "#7f849c", fontSize: 13 },
  focusButton: {
    marginTop: 8,
    backgroundColor: "#89b4fa",
    borderRadius: 8,
    paddingHorizontal: 18,
    paddingVertical: 10,
  },
  focusButtonText: { color: "#11111b", fontSize: 14, fontWeight: "600" },
});
