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

    /// v0.9: Send a `partial` request for streaming partial transcription.
    /// The daemon reads only bytes up to `endByteOffset` from the WAV file
    /// and returns the partial transcript. Used by the floating preview
    /// panel to show live feedback during PTT / continuous recording.
    /// Reuses the v0.8 daemon-side op (proven at 50-100ms response).
    func sendPartial(wavPath: String, endByteOffset: Int) throws -> String {
        let response = try sendBlocking([
            "op": "partial",
            "wav_path": wavPath,
            "end_byte_offset": endByteOffset
        ])
        guard response["ok"] as? Bool == true else {
            let err = response["error"] as? String ?? "unknown"
            throw DaemonError.serverError(err)
        }
        return (response["text"] as? String) ?? ""
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
        var wireData = jsonData
        wireData.append(0x0A)  // newline delimiter

        // Send (synchronous-ish via semaphore)
        let sendSem = DispatchSemaphore(value: 0)
        var sendError: Error?
        connection.send(content: wireData, completion: .contentProcessed { err in
            sendError = err
            sendSem.signal()
        })
        sendSem.wait()
        if let err = sendError {
            throw DaemonError.connectionFailed(err.localizedDescription)
        }

        // Read one line of response.
        // FIX-R5 (v0.9.7): recvData is now confined to the NWConnection's
        // internal queue — the calling thread only waits on the semaphore and
        // reads the buffer AFTER the final signal, under the lock. Previously
        // recvData/recvError were appended on the connection queue while this
        // loop read `recvData.last` unsynchronized (torn reads), and each spin
        // iteration stacked another concurrent receive completion onto the
        // same Data.
        let recvSem = DispatchSemaphore(value: 0)
        let recvLock = NSLock()
        var recvData = Data()

        func issueReceive(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                recvLock.lock()
                if let data = data { recvData.append(data) }
                let done = (err != nil) || recvData.last == 0x0A || isComplete
                recvLock.unlock()
                if done {
                    // Signal only once — semaphore value >1 would unblock
                    // subsequent wait() calls spuriously.
                    recvSem.signal()
                } else {
                    // Need more data — keep exactly ONE outstanding receive.
                    issueReceive(connection)
                }
            }
        }
        issueReceive(connection)

        // FIX-13: cap total wait at 8s. Partial and transcribe ops should
        // complete in <2s; if the daemon is stuck (model not loaded, lock held
        // by another request), we bail so the icon reverts to idle.
        let recvStart = Date()
        let recvTotalTimeout: TimeInterval = 8.0
        var timedOut = false
        while true {
            let remaining = recvTotalTimeout - Date().timeIntervalSince(recvStart)
            if remaining <= 0 {
                timedOut = true
                break
            }
            if recvSem.wait(timeout: .now() + min(remaining, 1.0)) == .success { break }
            // Check under lock whether data already completed the line but
            // the signal raced our wait.
            recvLock.lock()
            let haveLine = recvData.last == 0x0A
            recvLock.unlock()
            if haveLine { break }
        }

        if timedOut && recvData.isEmpty {
            wfLog("[WF:TC] daemon receive timed out after \(recvTotalTimeout)s — bailing")
            throw DaemonError.connectionFailed("receive timeout after \(recvTotalTimeout)s")
        }

        recvLock.lock()
        let data = recvData
        recvData = Data()
        recvLock.unlock()

        guard !data.isEmpty else {
            throw DaemonError.badResponse("empty response")
        }
        guard data.last == 0x0A else {
            // Truncated mid-line (timeout or EOF before newline) — treat as a
            // timeout, not a JSON parse failure, for accurate diagnostics.
            wfLog("[WF:TC] daemon response truncated after \(Date().timeIntervalSince(recvStart))s")
            throw DaemonError.connectionFailed("response truncated (daemon timeout)")
        }
        var line = data
        line.removeLast()  // strip trailing newline
        guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw DaemonError.badResponse("not a JSON object")
        }
        return response
    }
}
