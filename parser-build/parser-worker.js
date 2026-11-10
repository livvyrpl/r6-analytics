// Runs the replay parser away from the page, so the page never freezes.
// The Import page sends one file at a time and gets one result back.
// File contents stay in this browser. Nothing here sends them anywhere.
let stopped = false;
let ready;

try {
  importScripts('wasm_exec.js');
  const go = new Go();
  ready = fetch('parser.wasm' + self.location.search)
    .then(r => {
      if (!r.ok) throw new Error('The parser files are missing from the site.');
      return r.arrayBuffer();
    })
    .then(bytes => WebAssembly.instantiate(bytes, go.importObject))
    .then(({ instance }) => {
      go.run(instance).finally(() => { stopped = true; });
    });
} catch (err) {
  ready = Promise.reject(err);
}

self.onmessage = async e => {
  const { id, file } = e.data;
  try {
    await ready;
    if (stopped) throw new Error('The parser stopped unexpectedly.');
    const json = parseReplay(new Uint8Array(await file.arrayBuffer()));
    self.postMessage({ id, json });
  } catch (err) {
    // The parser can't be reused after this, so the page starts a new worker.
    self.postMessage({ id, fatal: String((err && err.message) || err) });
  }
};
