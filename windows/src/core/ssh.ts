// What the user types for a remote host, as one destination ssh takes after `--`.
// Same rules as SSHDestination.swift: a port ("host -p 2222" or "host:2222") becomes
// ssh's own `ssh://host:2222` form, and any other option is refused, so nothing typed
// here reaches ssh as an option.

const SSH_HOST = /^[A-Za-z0-9@._:[\]/-]{1,255}$/;

/** A destination ssh takes as a host and nothing else: never an option. */
export function validSshHost(host: string): boolean {
  return SSH_HOST.test(host) && !host.startsWith("-");
}

/** The destination for `typed`, or null when it is not a host (with an optional port). */
export function sshDestination(typed: string): string | null {
  const words = typed.split(/\s+/).filter(Boolean);
  let port: string | null = null;
  const i = words.findIndex((w) => w.startsWith("-p"));
  if (i >= 0) {
    if (words[i] === "-p" && i + 1 < words.length) {
      port = words[i + 1];
      words.splice(i, 2);
    } else {
      port = words[i].slice(2);
      words.splice(i, 1);
    }
  }
  if (words.length !== 1) return null;
  let host = words[0];

  // host:port, only where the colon cannot be part of an IPv6 address
  const colon = host.lastIndexOf(":");
  if (port == null && !host.startsWith("ssh://") && colon >= 0) {
    const before = host.slice(0, colon);
    if (!before.includes(":") || (before.startsWith("[") && before.endsWith("]"))) {
      port = host.slice(colon + 1);
      host = before;
    }
  }
  if (!validSshHost(host)) return null;
  if (port == null) return host;
  const n = Number(port);
  if (!/^\d+$/.test(port) || n < 1 || n > 65535 || host.startsWith("ssh://")) return null;
  return `ssh://${host}:${n}`;
}

/** The destination as people read it: no `ssh://`, no port. */
export function sshLabel(destination: string): string {
  if (!destination.startsWith("ssh://")) return destination;
  const rest = destination.slice("ssh://".length);
  const colon = rest.lastIndexOf(":");
  if (colon < 0 || rest.slice(colon).includes("]")) return rest;
  return rest.slice(0, colon);
}
