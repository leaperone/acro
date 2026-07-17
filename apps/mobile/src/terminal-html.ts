// WebView 内的 xterm.js 终端页。
// ponytail: xterm 走 CDN,开发阶段够用;离线打包进 assets 等真机验证时做。
// RN → Web:injectJavaScript 调 window.__acro.write(base64)
// Web → RN:ReactNativeWebView.postMessage JSON {type:'ready'|'input'|'resize', ...}

export const terminalHtml = `<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css" integrity="sha384-tStR1zLfWgsiXCF3IgfB3lBa8KmBe/lG287CL9WCeKgQYcp1bjb4/+mwN6oti4Co" crossorigin="anonymous">
<style>
  html, body { margin: 0; padding: 0; height: 100%; background: #1e1e2e; }
  #term { height: 100%; }
</style>
</head>
<body>
<div id="term"></div>
<script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js" integrity="sha384-J4qzUjBl1FxyLsl/kQPQIOeINsmp17OHYXDOMpMxlKX53ZfYsL+aWHpgArvOuof9" crossorigin="anonymous"></script>
<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js" integrity="sha384-XGqKrV8Jrukp1NITJbOEHwg01tNkuXr6uB6YEj69ebpYU3v7FvoGgEg23C1Gcehk" crossorigin="anonymous"></script>
<script>
  const term = new Terminal({
    fontSize: 13,
    fontFamily: 'Menlo, monospace',
    theme: { background: '#1e1e2e' },
    scrollback: 3000,
  });
  const fit = new FitAddon.FitAddon();
  term.loadAddon(fit);
  term.open(document.getElementById('term'));
  fit.fit();

  const send = (obj) => window.ReactNativeWebView.postMessage(JSON.stringify(obj));

  function b64ToBytes(b64) {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }
  function bytesToB64(str) {
    return btoa(unescape(encodeURIComponent(str)));
  }

  window.__acro = {
    write(b64) { term.write(b64ToBytes(b64)); },
    clear() { term.reset(); },
    focus() { term.focus(); },
    sendText(text) { send({ type: 'input', dataB64: bytesToB64(text) }); },
  };

  term.onData((data) => send({ type: 'input', dataB64: bytesToB64(data) }));
  window.addEventListener('resize', () => {
    fit.fit();
    send({ type: 'resize', cols: term.cols, rows: term.rows });
  });
  send({ type: 'ready', cols: term.cols, rows: term.rows });
</script>
</body>
</html>`;
