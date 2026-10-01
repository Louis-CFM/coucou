import Foundation

/// Returns the URL only if it is a plain web link (http/https with a host). Model output
/// and API data can carry file://, smb:// or custom app schemes that would launch local apps
/// or deep links; those never reach NSWorkspace.open.
func safeWebURL(_ string: String?) -> URL? {
    guard let string,
          let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
          let host = url.host, !host.isEmpty else { return nil }
    return url
}
