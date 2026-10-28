// Olaz page instrumentation, injected at document start.
// The official client hooks console + window errors the same way; without it a
// renderer crash only reaches the encrypted zlog and looks like a blank page.
(() => {
  if (window.__olazInstrumented) return;
  window.__olazInstrumented = true;
  const post = (level, args) => {
    try {
      window.webkit.messageHandlers.zlog.postMessage(
        level + ' ' + Array.prototype.map.call(args, (value) => {
          try {
            if (typeof value === 'string') return value;
            if (value instanceof Error) return value.message + ' | ' + String(value.stack || '').split('\n').slice(0, 3).join(' < ');
            return JSON.stringify(value);
          } catch { return String(value); }
        }).join(' ').slice(0, 1200)
      );
    } catch {}
  };
  for (const level of ['log', 'warn', 'error', 'info']) {
    const original = console[level];
    console[level] = (...args) => { post('[' + level + ']', args); return original.apply(console, args); };
  }
  window.__olazRejections = [];
  window.__olazNetCalls = [];
  const noteNet = (kind, url) => {
    if (window.__olazNetCalls.length < 40) window.__olazNetCalls.push(kind + ' ' + String(url).slice(0, 120));
  };
  const origFetch = window.fetch;
  if (origFetch) window.fetch = function (input, init) { noteNet('fetch', input && input.url ? input.url : input); return origFetch.call(this, input, init); };
  const origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url, ...rest) { noteNet('xhr', url); return origOpen.call(this, method, url, ...rest); };
  addEventListener('error', (event) => post('[uncaught]', [event.message + ' @ ' + event.filename + ':' + event.lineno + ':' + event.colno]));
  addEventListener('unhandledrejection', (event) => {
    const reason = event.reason;
    let text;
    if (reason instanceof Error) text = reason.message + ' | ' + String(reason.stack || '').split('\n').slice(0, 4).join(' < ');
    else { try { text = JSON.stringify(reason); } catch { text = String(reason); } }
    window.__olazRejections.push(String(text).slice(0, 300));
    post('[unhandled]', [text]);
  });
})();
