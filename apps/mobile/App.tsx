import { useCallback, useEffect, useRef, useState } from "react";
import {
  ActivityIndicator,
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
import type { Session } from "@acro/protocol";
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

function HomeScreen({
  client,
  onOpen,
}: {
  client: MobileClient;
  onOpen: (route: Route) => void;
}) {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [sims, setSims] = useState<SimInfo[]>([]);

  const refreshSessions = useCallback(() => {
    void client.rpc("session.list", {}).then(setSessions).catch(() => {});
  }, [client]);

  const refreshSimulators = useCallback(() => {
    void client.rpc("simulator.list", {}).then(setSims).catch(() => {});
  }, [client]);

  useEffect(() => {
    refreshSessions();
    refreshSimulators();
    return client.subscribeEvent((event) => {
      if (event === "session.created" || event === "session.exit" || event === "session.removed") {
        refreshSessions();
      }
    });
  }, [client, refreshSessions, refreshSimulators]);

  const createSession = (command?: string) => {
    void client
      .rpc("session.create", {
        ...(command ? { command } : {}),
        cols: 80,
        rows: 24,
      })
      .then((s) => onOpen({ name: "terminal", session: s }))
      .catch(() => {});
  };

  return (
    <View style={styles.flex}>
      <Text style={styles.header}>Acro</Text>
      <FlatList
        data={sessions}
        keyExtractor={(s) => s.id}
        ListHeaderComponent={
          <View>
            <Pressable style={styles.row} onPress={() => createSession()}>
              <Text style={styles.rowText}>新建终端</Text>
              <Text style={styles.dim}>打开</Text>
            </Pressable>
            <Text style={styles.section}>会话</Text>
          </View>
        }
        renderItem={({ item: s }) => (
          <Pressable
            style={styles.row}
            onPress={() => s.alive && onOpen({ name: "terminal", session: s })}
          >
            <Text style={[styles.rowText, !s.alive && styles.dead]} numberOfLines={1}>
              {s.command}
            </Text>
            <Text style={styles.dim}>{s.alive ? "attach" : `exit ${s.exitCode ?? "?"}`}</Text>
          </Pressable>
        )}
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

  const inject = useCallback((js: string) => {
    if (terminalDocumentActiveRef.current) {
      webRef.current?.injectJavaScript(`${js}; true;`);
    }
  }, []);

  const attach = useCallback(
    async (cols: number, rows: number) => {
      const res = await client.rpc("session.attach", { sessionId: session.id });
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
    const unsubscribeFrame = client.subscribeFrame((frame) => {
      if (frame.type === FRAME_OUT && frame.channel === channelRef.current) {
        inject(`${bridgeExpression}?.write("${bytesToB64(frame.data)}")`);
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
            void attach(msg.cols, msg.rows).catch(() => {});
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
    const unsubscribeFrame = client.subscribeFrame((frame) => {
      if (
        (frame.type === FRAME_BROWSER || frame.type === FRAME_SIM) &&
        frame.channel === channelRef.current
      ) {
        const mime = frame.type === FRAME_BROWSER ? "image/jpeg" : "image/png";
        setFrameUri(`data:${mime};base64,${bytesToB64(frame.data)}`);
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
  dim: { color: "#7f849c", fontSize: 13 },
  sub: { backgroundColor: "#181825" },
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
