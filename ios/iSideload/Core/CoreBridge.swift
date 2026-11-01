import Foundation

/// A question the Rust core asks the UI while an operation runs.
struct CorePrompt: Identifiable {
    let id = UUID()
    let kind: String          // "2fa", "revoke"
    let payload: [String: Any]
}

/// Thin wrapper around the C FFI of the Rust core (`isl_call`).
final class CoreCall {
    typealias Event = (_ stage: String, _ progress: Double) -> Void
    /// Return nil to cancel. Called off the main thread; may block.
    typealias Prompt = (CorePrompt) -> String?

    private let onEvent: Event
    private let onPrompt: Prompt

    private init(onEvent: @escaping Event, onPrompt: @escaping Prompt) {
        self.onEvent = onEvent
        self.onPrompt = onPrompt
    }

    /// Runs one core operation synchronously. Call from a background thread.
    static func run(_ request: [String: Any], onEvent: @escaping Event = { _, _ in },
                    onPrompt: @escaping Prompt = { _ in nil }) -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8) else {
            return ["ok": false, "error": "Bad request"]
        }
        let box = CoreCall(onEvent: onEvent, onPrompt: onPrompt)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<CoreCall>.fromOpaque(ctx).release() }

        let ev: isl_event_cb = { ctx, json in
            guard let ctx, let json else { return }
            let me = Unmanaged<CoreCall>.fromOpaque(ctx).takeUnretainedValue()
            let obj = (try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8))) as? [String: Any] ?? [:]
            me.onEvent(obj["stage"] as? String ?? "", obj["progress"] as? Double ?? 0)
        }
        let pr: isl_prompt_cb = { ctx, json, out, cap in
            guard let ctx, let json, let out, cap > 0 else { return 1 }
            let me = Unmanaged<CoreCall>.fromOpaque(ctx).takeUnretainedValue()
            let obj = (try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8))) as? [String: Any] ?? [:]
            guard let answer = me.onPrompt(CorePrompt(kind: obj["kind"] as? String ?? "", payload: obj)) else { return 1 }
            let bytes = Array(answer.utf8.prefix(Int(cap) - 1))
            for (i, b) in bytes.enumerated() { out[i] = CChar(bitPattern: b) }
            out[bytes.count] = 0
            return 0
        }
        guard let raw = isl_call(json, ev, pr, ctx) else { return ["ok": false, "error": "Core returned nothing"] }
        defer { isl_string_free(raw) }
        let text = String(cString: raw)
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            ?? ["ok": false, "error": text]
    }

    static func runAsync(_ request: [String: Any], onEvent: @escaping Event = { _, _ in },
                         onPrompt: @escaping Prompt = { _ in nil }) async -> [String: Any] {
        await withCheckedContinuation { cont in
            Thread.detachNewThread {
                cont.resume(returning: run(request, onEvent: onEvent, onPrompt: onPrompt))
            }
        }
    }

    static var version: String {
        run(["op": "version"])["version"] as? String ?? "?"
    }
}

struct CoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension Dictionary where Key == String, Value == Any {
    func checked() throws -> [String: Any] {
        if self["ok"] as? Bool == true { return self }
        let e = self["error"] as? String ?? "Lỗi không rõ"
        let h = self["hint"] as? String ?? ""
        throw CoreError(message: h.isEmpty ? e : "\(h)\n\nChi tiết: \(e)")
    }
}
