// FLUTTER HOST ONLY. "Ask Musey" for Siri, the Shortcuts app, widgets and the
// Action button (build 182, docs/MUSEY-SIRI.md).
//
// The intent runs in the app process without opening the app
// (`openAppWhenRun = false`). It does not talk to the relay itself: the
// server address and token live in Open WebUI's session inside Dart, and
// Bobby's tools run through that session. So the question goes to Dart over
// one method channel, Dart sends it into the Omni chat the way typing does,
// and the answer comes back as words for Siri to say.

import AppIntents
import Flutter
import Foundation

/// What Dart reports for one question.
struct AskMuseyReply {
    enum Status: String {
        case reply, card, slow, error
    }

    let status: Status
    let spoken: String
}

/// The native end of `am.tamm.conduit/ask_musey`. Dart answers `ask` and tells
/// us `ready` once it is signed in and listening.
final class AskMuseyBridge: @unchecked Sendable {
    static let shared = AskMuseyBridge()
    static let channelName = "am.tamm.conduit/ask_musey"

    /// Everything, start to finish, stays under this. Intents are cut off at
    /// about 30 s (unverified on a device), so there is margin.
    static let totalBudget: TimeInterval = 24
    /// How long to wait for a cold app to finish starting.
    static let readyBudget: TimeInterval = 7
    /// Dart gets this much less than what is left, to answer and cross back.
    static let returnMargin: TimeInterval = 1.5

    private let lock = NSLock()
    private var channel: FlutterMethodChannel?
    private var readiness = AppIntentReadiness()

    private init() {}

    func configure(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: Self.channelName,
            binaryMessenger: messenger
        )
        let fresh = AppIntentReadiness()
        lock.lock()
        self.channel = channel
        readiness = fresh
        lock.unlock()
        channel.setMethodCallHandler { call, result in
            if call.method == "ready" {
                fresh.update(true)
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func current() -> (FlutterMethodChannel?, AppIntentReadiness) {
        lock.lock()
        defer { lock.unlock() }
        return (channel, readiness)
    }

    /// Sends [question] and waits for Dart's answer, never longer than the
    /// total budget. Anything that goes wrong is an `error` reply that says
    /// so; a question is never reported as sent unless Dart said it was.
    func ask(_ question: String) async -> AskMuseyReply {
        let started = ProcessInfo.processInfo.systemUptime
        func left() -> TimeInterval {
            Self.totalBudget - (ProcessInfo.processInfo.systemUptime - started)
        }
        let notReady = AskMuseyReply(
            status: .error,
            spoken: appLocalized(
                "askMusey.notReady",
                "Musey isn't ready. Open it and try again."
            )
        )

        let (channel, readiness) = current()
        guard let channel else { return notReady }
        let wait = min(Self.readyBudget, max(0, left() - Self.returnMargin))
        guard await readiness.waitUntilReady(
            timeoutNanoseconds: UInt64(wait * 1_000_000_000)
        ) else { return notReady }

        let dartMs = Int(max(0, left() - Self.returnMargin) * 1000)
        guard dartMs >= 2000 else { return notReady }

        // The hard cap guards a Dart side that never answers. The question
        // may have been sent by then, so the line must not claim either way.
        let hardCap = UInt64(max(0.5, left()) * 1_000_000_000)
        return await withTaskGroup(of: AskMuseyReply?.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    channel.invokeMethod(
                        "ask",
                        arguments: ["question": question, "deadline_ms": dartMs]
                    ) { raw in
                        continuation.resume(returning: Self.parse(raw))
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: hardCap)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? AskMuseyReply(
                status: .slow,
                spoken: appLocalized(
                    "askMusey.slow",
                    "Bobby is still thinking, it's in Musey."
                )
            )
        }
    }

    static func parse(_ raw: Any?) -> AskMuseyReply {
        guard let map = raw as? [String: Any],
              let name = map["status"] as? String,
              let status = AskMuseyReply.Status(rawValue: name),
              let spoken = map["spoken"] as? String,
              !spoken.isEmpty
        else {
            return AskMuseyReply(
                status: .error,
                spoken: appLocalized(
                    "askMusey.noAnswer",
                    "I didn't get an answer. Check Musey."
                )
            )
        }
        return AskMuseyReply(status: status, spoken: spoken)
    }
}

@available(iOS 16.0, *)
struct AskMuseyIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Musey"
    static var description = IntentDescription(
        "Ask Bobby a question and hear the answer. Anything that would change something comes back as a card in Musey and is never done without you."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = false

    @Parameter(
        title: "Question",
        requestValueDialog: IntentDialog("What do you want to ask Bobby?")
    )
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Musey \(\.$question)")
    }

    init() {}

    init(question: String) {
        self.question = question
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw $question.needsValueError(
                IntentDialog("What do you want to ask Bobby?")
            )
        }
        let reply = await AskMuseyBridge.shared.ask(text)
        // A card is spoken as its own line plus where to confirm it. Nothing
        // is confirmed from here.
        let line: String
        switch reply.status {
        case .card:
            line = "\(reply.spoken) \(appLocalized("askMusey.confirmInMusey", "Confirm it in Musey."))"
        default:
            line = reply.spoken
        }
        return .result(value: line, dialog: IntentDialog(stringLiteral: line))
    }
}
