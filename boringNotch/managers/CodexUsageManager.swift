import Foundation
import SwiftUI

struct CodexUsageSnapshot: Equatable, Sendable {
    let weeklyRemaining: Int
    let weeklyResetAt: Date
    let planType: String?
}

enum CodexUsageState: Equatable {
    case idle
    case loading
    case loaded(CodexUsageSnapshot)
    case signedOut
    case failed(String)
}

@MainActor
final class CodexUsageManager: ObservableObject {
    static let shared = CodexUsageManager()

    @Published private(set) var state: CodexUsageState = .idle
    @Published private(set) var lastUpdated: Date?

    private var refreshTask: Task<Void, Never>?
    private var lastRefreshAt: Date?

    private init() {}

    var snapshot: CodexUsageSnapshot? {
        guard case let .loaded(snapshot) = state else { return nil }
        return snapshot
    }

    func refreshIfNeeded() {
        guard state != .loading else { return }
        if let lastRefreshAt,
           Date().timeIntervalSince(lastRefreshAt) < 300 {
            return
        }
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        state = .loading
        lastRefreshAt = Date()

        refreshTask = Task { [weak self] in
            let result = await XPCHelperClient.shared.readCodexUsage()
            guard !Task.isCancelled else { return }

            guard let self else { return }
            if let payload = result.payload {
                self.apply(payload: payload)
            } else {
                let message = result.error ?? "无法读取 Codex 额度"
                if message.localizedCaseInsensitiveContains("authentication")
                    || message.localizedCaseInsensitiveContains("logged")
                    || message.localizedCaseInsensitiveContains("sign") {
                    self.state = .signedOut
                } else {
                    self.state = .failed(message)
                }
            }
        }
    }

    func resetText(at date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let remainingMinutes = minutes % 60

        if days > 0 {
            return "\(days)天\(hours)小时"
        }
        if hours > 0 {
            return "\(hours)小时\(remainingMinutes)分"
        }
        return "\(remainingMinutes)分钟"
    }

    private func apply(payload: String) {
        guard let data = payload.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountResult = envelope["account"] as? [String: Any]
        else {
            state = .failed("Codex 返回了无法识别的数据")
            return
        }

        let account = accountResult["account"]
        guard account != nil, !(account is NSNull) else {
            state = .signedOut
            return
        }

        guard let rateLimitsEnvelope = envelope["rateLimits"] as? [String: Any],
              let rateLimits = preferredRateLimits(from: rateLimitsEnvelope),
              let weeklyWindow = findWeeklyWindow(in: rateLimits),
              let usedPercent = number(rateLimitsWindowValue(weeklyWindow, key: "usedPercent")),
              let resetsAt = number(rateLimitsWindowValue(weeklyWindow, key: "resetsAt"))
        else {
            state = .failed("暂时没有可用的 Codex 周额度")
            return
        }

        let remaining = max(0, min(100, 100 - Int(usedPercent.rounded())))
        let planType = (account as? [String: Any])?["planType"] as? String
        state = .loaded(
            CodexUsageSnapshot(
                weeklyRemaining: remaining,
                weeklyResetAt: Date(timeIntervalSince1970: resetsAt),
                planType: planType
            )
        )
        lastUpdated = Date()
    }

    private func preferredRateLimits(from envelope: [String: Any]) -> [String: Any]? {
        if let byLimitID = envelope["rateLimitsByLimitId"] as? [String: Any],
           let codex = byLimitID["codex"] as? [String: Any] {
            return codex
        }
        return envelope["rateLimits"] as? [String: Any]
    }

    private func findWeeklyWindow(in rateLimits: [String: Any]) -> [String: Any]? {
        ["primary", "secondary"]
            .compactMap { rateLimits[$0] as? [String: Any] }
            .first { number($0["windowDurationMins"]) == 10080 }
    }

    private func rateLimitsWindowValue(_ window: [String: Any], key: String) -> Any? {
        window[key]
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
