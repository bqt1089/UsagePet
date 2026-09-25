import Foundation

/// Pure, unit-testable parsing of the Antigravity process-discovery data
/// (`ps`/`lsof` output). No I/O here — `AntigravityClient` does the actual
/// process invocation and keeps this file's logic testable on any platform.
public enum AntigravityProcessInfo {

    /// Parses one line of `ps -axww -o pid=,command=` output, returning the
    /// pid and CSRF token when the line looks like the Antigravity language
    /// server: it mentions "antigravity" (case-insensitively) and carries a
    /// `--csrf_token` flag, in either `--csrf_token=VALUE` or
    /// `--csrf_token VALUE` form.
    public static func parse(psLine: String) -> (pid: Int32, csrfToken: String)? {
        let trimmed = psLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        guard lower.contains("antigravity"), lower.contains("--csrf_token") else { return nil }

        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = tokens.first, let pid = Int32(first) else { return nil }

        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--csrf_token=") {
                let value = String(token.dropFirst("--csrf_token=".count))
                return value.isEmpty ? nil : (pid, value)
            }
            if token == "--csrf_token", index + 1 < tokens.count {
                let value = tokens[index + 1]
                if value.isEmpty || value.hasPrefix("--") { return nil }
                return (pid, value)
            }
            index += 1
        }
        return nil
    }

    /// Parses `lsof -nP -a -iTCP -sTCP:LISTEN -p <pid>` output, returning the
    /// distinct TCP ports it's listening on, in first-seen order. Handles
    /// both the `127.0.0.1:56725` and `*:56726` NAME-column forms, and
    /// ignores the header row and anything else that doesn't match.
    public static func parseListenPorts(lsofOutput: String) -> [Int] {
        // Matches "<ipv4>:<port>", "*:<port>", or "[<ipv6>]:<port>".
        let pattern = #"(?:\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}|\*|\[[^\]]*\]):(\d{1,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var ports: [Int] = []
        var seen = Set<Int>()
        for line in lsofOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineString = String(line)
            let range = NSRange(lineString.startIndex..., in: lineString)
            guard let match = regex.firstMatch(in: lineString, range: range),
                  let portRange = Range(match.range(at: 1), in: lineString),
                  let port = Int(lineString[portRange]) else { continue }
            if !seen.contains(port) {
                seen.insert(port)
                ports.append(port)
            }
        }
        return ports
    }
}
