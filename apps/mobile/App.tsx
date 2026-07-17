import { useCallback, useEffect, useRef, useState } from "react";
import {
  ActivityIndicator,
  FlatList,
  Image,
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
import type { Project, Session, Worktree } from "@acro/protocol";
import { encodeInFrame, FRAME_BROWSER, FRAME_OUT, FRAME_SIM } from "@acro/protocol";
import { MobileClient, pairWithHost } from "./src/client.ts";
import { terminalHtml } from "./src/terminal-html.ts";

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

interface StoredConfig {
  host: string;
  token: string;
}

// ---- 根组件 ----

export default function App() {
  const [config, setConfig] = useState<StoredConfig | null | undefined>(undefined);
  const [client, setClient] = useState<MobileClient | null>(null);
  const [connected, setConnected] = useState(false);
  const [route, setRoute] = useState<Route>({ name: "home" });

  useEffect(() => {
    void (async () => {
      const raw = await SecureStore.getItemAsync("acro.config");
      setConfig(raw ? (JSON.parse(raw) as StoredConfig) : null);
    })();
  }, []);

  useEffect(() => {
    if (!config) return;
    const c = new MobileClient(config.host, config.token);
    c.onStateChange = setConnected;
    void c.connect().catch(() => {});
    setClient(c);
    return () => c.close();
  }, [config]);

  const onPaired = useCallback(async (host: string, code: string) => {
    const { token } = await pairWithHost(host, code, "iPhone");
    const cfg = { host, token };
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
          <Text style={styles.dim}>连接 {config.host} …</Text>
          <Pressable
            style={styles.buttonGhost}
            onPress={() => {
              void SecureStore.deleteItemAsync("acro.config");
              client?.close();
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

function PairScreen({ onPaired }: { onPaired: (host: string, code: string) => Promise<void> }) {
  const [host, setHost] = useState("");
  const [code, setCode] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  return (
    <SafeAreaView style={styles.root}>
      <StatusBar style="light" />
      <View style={styles.pairBox}>
        <Text style={styles.title}>Acro</Text>
        <TextInput
          style={styles.input}
          placeholder="Mac mini 地址 (host:port)"
          placeholderTextColor="#666"
          autoCapitalize="none"
          autoCorrect={false}
          value={host}
          onChangeText={setHost}
        />
        <TextInput
          style={styles.input}
          placeholder="配对码"
          placeholderTextColor="#666"
          autoCapitalize="characters"
          autoCorrect={false}
          value={code}
          onChangeText={setCode}
        />
        {error ? <Text style={styles.error}>{error}</Text> : null}
        <Pressable
          style={styles.button}
          disabled={busy}
          onPress={() => {
            setBusy(true);
            setError("");
            onPaired(host.trim(), code.trim()).catch((e: Error) => {
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
  const [projects, setProjects] = useState<Project[]>([]);
  const [sessions, setSessions] = useState<Session[]>([]);
  const [sims, setSims] = useState<SimInfo[]>([]);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [worktrees, setWorktrees] = useState<Worktree[]>([]);
  const [newBranch, setNewBranch] = useState("");

  const refresh = useCallback(() => {
    void client.rpc("project.list", {}).then(setProjects).catch(() => {});
    void client.rpc("session.list", {}).then(setSessions).catch(() => {});
    void client.rpc("simulator.list", {}).then(setSims).catch(() => {});
  }, [client]);

  useEffect(() => {
    refresh();
    client.onEvent = () => refresh();
    return () => {
      client.onEvent = null;
    };
  }, [client, refresh]);

  const openProject = (p: Project) => {
    setExpanded(expanded === p.id ? null : p.id);
    void client.rpc("worktree.list", { projectId: p.id }).then(setWorktrees).catch(() => {});
  };

  const createSession = (worktreeId?: string, projectId?: string, command?: string) => {
    void client
      .rpc("session.create", {
        ...(worktreeId ? { worktreeId } : {}),
        ...(projectId ? { projectId } : {}),
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
        data={projects}
        keyExtractor={(p) => p.id}
        ListHeaderComponent={<Text style={styles.section}>项目</Text>}
        renderItem={({ item: p }) => (
          <View>
            <Pressable style={styles.row} onPress={() => openProject(p)}>
              <Text style={styles.rowText}>{p.name}</Text>
              <Text style={styles.dim}>{expanded === p.id ? "▾" : "▸"}</Text>
            </Pressable>
            {expanded === p.id && (
              <View style={styles.sub}>
                {worktrees.map((w) => (
                  <Pressable
                    key={w.id}
                    style={styles.row}
                    onPress={() => createSession(w.id)}
                  >
                    <Text style={styles.rowText}>
                      {w.isMain ? "◆ " : "◇ "}
                      {w.branch ?? "(detached)"}
                    </Text>
                    <Text style={styles.dim}>开终端</Text>
                  </Pressable>
                ))}
                <View style={styles.newRow}>
                  <TextInput
                    style={[styles.input, styles.flex]}
                    placeholder="新分支名"
                    placeholderTextColor="#666"
                    autoCapitalize="none"
                    value={newBranch}
                    onChangeText={setNewBranch}
                  />
                  <Pressable
                    style={styles.buttonSmall}
                    onPress={() => {
                      if (!newBranch.trim()) return;
                      void client
                        .rpc("worktree.create", { projectId: p.id, branch: newBranch.trim() })
                        .then((w) => {
                          setNewBranch("");
                          createSession(w.id);
                        })
                        .catch(() => {});
                    }}
                  >
                    <Text style={styles.buttonText}>建 Worktree</Text>
                  </Pressable>
                </View>
              </View>
            )}
          </View>
        )}
        ListFooterComponent={
          <View>
            <Text style={styles.section}>会话</Text>
            {sessions.map((s) => (
              <Pressable
                key={s.id}
                style={styles.row}
                onPress={() => s.alive && onOpen({ name: "terminal", session: s })}
              >
                <Text style={[styles.rowText, !s.alive && styles.dead]} numberOfLines={1}>
                  {s.command}
                </Text>
                <Text style={styles.dim}>{s.alive ? "attach" : `exit ${s.exitCode ?? "?"}`}</Text>
              </Pressable>
            ))}
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

  const inject = useCallback((js: string) => {
    webRef.current?.injectJavaScript(`${js}; true;`);
  }, []);

  const attach = useCallback(
    async (cols: number, rows: number) => {
      const res = await client.rpc("session.attach", { sessionId: session.id });
      channelRef.current = res.channel;
      inject(`window.__acro.clear()`);
      inject(`window.__acro.write(${JSON.stringify(res.snapshot)})`);
      if (cols !== res.cols || rows !== res.rows) {
        await client.rpc("session.resize", { sessionId: session.id, cols, rows });
      }
    },
    [client, session.id, inject],
  );

  useEffect(() => {
    client.onFrame = (frame) => {
      if (frame.type === FRAME_OUT && frame.channel === channelRef.current) {
        inject(`window.__acro.write("${bytesToB64(frame.data)}")`);
      }
    };
    // 断线重连后重新 attach(快照重画)
    client.onStateChange = (up) => {
      if (up && channelRef.current !== null) void attach(0, 0).catch(() => {});
    };
    return () => {
      client.onFrame = null;
      client.onStateChange = null;
      void client.rpc("session.detach", { sessionId: session.id }).catch(() => {});
    };
  }, [client, session.id, attach, inject]);

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
        source={{ html: terminalHtml }}
        style={styles.flex}
        originWhitelist={["*"]}
        keyboardDisplayRequiresUserAction={false}
        onMessage={(ev) => {
          const msg = JSON.parse(ev.nativeEvent.data) as
            | { type: "ready"; cols: number; rows: number }
            | { type: "input"; dataB64: string }
            | { type: "resize"; cols: number; rows: number };
          if (msg.type === "ready") {
            void attach(msg.cols, msg.rows).catch(() => {});
          } else if (msg.type === "input") {
            const channel = channelRef.current;
            if (channel !== null) client.sendBinary(encodeInFrame(channel, b64ToBytes(msg.dataB64)));
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
    client.onFrame = (frame) => {
      if (
        (frame.type === FRAME_BROWSER || frame.type === FRAME_SIM) &&
        frame.channel === channelRef.current
      ) {
        const mime = frame.type === FRAME_BROWSER ? "image/jpeg" : "image/png";
        setFrameUri(`data:${mime};base64,${bytesToB64(frame.data)}`);
      }
    };
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
      client.onFrame = null;
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
          const scale = size.w / layoutRef.current.w;
          void client
            .rpc("browser.input", {
              browserId: refId,
              event: {
                kind: "click",
                x: e.nativeEvent.locationX * scale,
                y: e.nativeEvent.locationY * scale,
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
  newRow: { flexDirection: "row", gap: 8, padding: 12, alignItems: "center" },
  pairBox: { flex: 1, justifyContent: "center", padding: 24, gap: 12 },
  input: {
    backgroundColor: "#1e1e2e",
    color: "#cdd6f4",
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    fontSize: 15,
  },
  error: { color: "#f38ba8" },
  button: {
    backgroundColor: "#89b4fa",
    borderRadius: 8,
    paddingVertical: 12,
    alignItems: "center",
  },
  buttonSmall: {
    backgroundColor: "#89b4fa",
    borderRadius: 8,
    paddingVertical: 10,
    paddingHorizontal: 12,
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
});
