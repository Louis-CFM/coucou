// A stand-in for the object Tauri injects into the webview. The island talks to
// Rust through it, so the tests see every command the island sends and can fire
// the events Rust would emit — through the real bridge, with no source changes.

/** Every command the island invoked, oldest first: [name, args]. */
export const calls = [];

const listeners = new Map();

export const internals = {
  transformCallback: (callback) => callback,
  invoke: async (cmd, args) => {
    if (cmd === "plugin:event|listen") {
      listeners.set(args.event, args.handler);
      return listeners.size;
    }
    calls.push([cmd, args]);
    return null;
  },
};

/** Fires an event the way the Rust side would. */
export function emit(event, payload) {
  const handler = listeners.get(event);
  if (!handler) throw new Error(`nothing listens to "${event}"`);
  handler({ event, id: 0, payload });
}

/** The commands invoked under one name, as a list of their arguments. */
export function sent(cmd) {
  return calls.filter(([name]) => name === cmd).map(([, args]) => args);
}
