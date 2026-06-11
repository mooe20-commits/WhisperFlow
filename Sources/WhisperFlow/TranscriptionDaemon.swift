import Foundation
import Network

/// Unix-socket client to `wf-transcribe-daemon`.
///
/// Used when the user has selected the "daemon" engine. Falls back to
/// `TranscriptionProcessRunner` (subprocess) if the daemon isn't running.
///
/// Protocol: line-delimited JSON. See `wf-transcribe-daemon` for details.
final class TranscriptionDaemon {
    static let socketPath = "/tmp/wf-transcribe.sock"
    static let pidPath = "/tmp/wf-transcribe.pid"

    enum DaemonError: Error, CustomStringConvertible {
        case daemonNotRunning
        case connectionFailed(String)
        case badResponse(String)
        case serverError(String)

        var description: String {
            switch self {
            case .daemonNotRunning:        return "daemon not running"
            case .connectionFailed(let m): return "connection failed: \(m)"
            case .badResponse(let m):      return "bad response: \(m)"
            case .serverError(let m):      return "server error: \(m)"
            }
        }
    }

    /// True if the daemon process appears to be alive (PID file + process exists).
    static func isRunning() -> Bool {
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(pidStr.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return false
        }
        return kill(pid, 0) == 0
    }

    /// True if we can establish a TCP-over-Unix-socket connection to the
    /// daemon. Used to verify the daemon is not just alive but actually
    /// listening. Times out after 1 second.
    static func isReachable() -> Bool {
        let endpoint = NWEndpoint.unix(path: socketPath)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "wf.daemon.reachability")
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ok = true
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 1.0)
        connection.cancel()
        return ok
    }

    // MARK: - Operations

    /// Send a `transcribe` request and return the text. Throws on failure.
    func transcribe(wavPath: String) throws -> String {
        let response = try sendBlocking(["op": "transcribe", "wav_path": wavPath])
        guard response["ok"] as? Bool == true else {
            let err = response["error"] as? String ?? "unknown"
            throw DaemonError.serverError(err)
        }
        return (response["text"] as? String) ?? ""
    }

    /// Send a `switch` request. The daemon will reload the model.
    @discardableResult
    func switchModel(_ model: String) throws -> Bool {
        let response = try sendBlocking(["op": "switch", "model": model])
        return response["ok"] as? Bool == true
    }

    /// Send a `ping` to check the daemon is alive and learn the loaded model.
    func ping() throws -> [String: Any] {
        return try sendBlocking(["op": "ping"])
    }

    /// Send `shutdown` so the daemon exits gracefully and releases the model.
    /// Returns the daemon's response. Caller is responsible for waiting
    /// on the process to actually exit (use `isRunning()` to poll).
    func sendShutdown() throws -> [String: Any] {
        return try sendBlocking(["op": "shutdown"])
    }

    // MARK: - Internal: synchronous line-delimited JSON over Unix socket

    /// Synchronous send + receive. Sends one JSON line, reads one JSON line
    /// back, returns the parsed dictionary.
    private func sendBlocking(_ payload: [String: Any]) throws -> [String: Any] {
        let endpoint = NWEndpoint.unix(path: Self.socketPath)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "wf.daemon.client")

        // Connection state — we use a semaphore to wait for it.
        let semaphore = DispatchSemaphore(value: 0)
        var connectionError: Error?

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let err):
                connectionError = err
                semaphore.signal()
            case .cancelled:
                connectionError = NSError(domain: "WF", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "connection cancelled"
                ])
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        if semaphore.wait(timeout: .now() + 2.0) == .timedOut {
            connection.cancel()
            throw DaemonError.daemonNotRunning
        }
        if connectionError != nil {
            connection.cancel()
            // Treat any NWError as "daemon not running" so caller falls back
            // to subprocess silently
            throw DaemonError.daemonNotRunning
        }

        defer { connection.cancel() }

        // Serialize payload
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        var line = jsonData
        line.append(0x0A)  // newline delimiter

        // Send (synchronous-ish via semaphore)
        let sendSem = DispatchSemaphore(value: 0)
        var sendError: Error?
        connection.send(content: line, completion: .contentProcessed { err in
            sendError = err
            sendSem.signal()
        })
        sendSem.wait()
        if let err = sendError {
            throw DaemonError.connectionFailed(err.localizedDescription)
        }

        // Read one line of response
        let recvSem = DispatchSemaphore(value: 0)
        var recvData = Data()
        var recvError: Error?
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
            if let data = data { recvData.append(data) }
            recvError = err
            // The daemon always sends exactly one line and closes. Keep
            // reading until we see the newline.
            if !recvData.isEmpty, recvData.last == 0x0A {
                recvSem.signal()
            } else if isComplete {
                recvSem.signal()
            } else if err != nil {
                recvSem.signal()
            }
        }
        // Spin: NWConnection.receive is one-shot; loop until newline
        var spinCount = 0
        while recvData.isEmpty || recvData.last != 0x0A {
            if spinCount > 100 { break }   // safety
            spinCount += 1
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                if let data = data { recvData.append(data) }
                recvError = err
                if isComplete || err != nil { recvSem.signal() }
            }
            if recvSem.wait(timeout: .now() + 5.0) == .timedOut { break }
            if recvError != nil { break }
        }

        guard !recvData.isEmpty else {
            throw DaemonError.badResponse("empty response")
        }
        // Strip the trailing newline
        if recvData.last == 0x0A { recvData.removeLast() }
        guard let response = try JSONSerialization.jsonObject(with: recvData) as? [String: Any] else {
            throw DaemonError.badResponse("not a JSON object")
        }
        return response
    }
}
