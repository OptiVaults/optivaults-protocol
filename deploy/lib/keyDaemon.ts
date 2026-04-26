/**
 * Resolve the key-daemon UNIX socket path.
 *
 * Operators set the `KEY_DAEMON_SOCKET` environment variable (typically
 * via `keeper/.env`) to point at their local key daemon socket. The
 * fallback `/path/to/key-daemon-preprod.sock` is a placeholder — it does
 * not exist on disk, so an unset env var fails fast at connect time with
 * a clear ENOENT instead of silently using someone else's path.
 */
export const DEFAULT_KEY_DAEMON_SOCKET = "/path/to/key-daemon-preprod.sock";

export function getKeyDaemonSocket(): string {
  return process.env.KEY_DAEMON_SOCKET || DEFAULT_KEY_DAEMON_SOCKET;
}
