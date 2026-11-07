//
//  NextEventAttributes.swift
//
//  The Live Activity for "next event". One file, compiled into both the Runner
//  app and the ConduitWidgetExtension, so the two never drift. The names and
//  keys are a contract with the relay (lan-relay/live-activity.js, see
//  docs/MUSEY-LIVE-ACTIVITY.md): do not rename them on one side only.
//

import ActivityKit
import Foundation

@available(iOS 16.1, *)
struct NextEventAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// "Standup", or "Nothing else today" when emptyDay.
        var title: String
        /// UTC instant, ISO 8601 with Z; "" when emptyDay.
        var startISO: String
        /// Calendar name, "" when unknown or emptyDay.
        var calendar: String
        /// Minutes to the start when the relay sent it. A snapshot: the view
        /// counts down from startISO.
        var minutesUntil: Int
        /// True when nothing is left today.
        var emptyDay: Bool

        /// The start instant, or nil on an empty day or an unreadable string.
        var startDate: Date? {
            if startISO.isEmpty { return nil }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: startISO) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: startISO)
        }
    }

    /// Fixed "Next event".
    var label: String
}
