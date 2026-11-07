//
//  NextEventLiveActivity.swift
//  ConduitWidget
//
//  Lock Screen and Dynamic Island for the next calendar event. The relay starts
//  and updates it (push-to-start); the app only registers tokens. The countdown
//  is drawn by the system from the start time, so it ticks without any push.
//

import ActivityKit
import SwiftUI
import WidgetKit

private let museyBlue = Color(red: 0.231, green: 0.576, blue: 0.980)

@available(iOS 16.2, *)
struct NextEventLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NextEventAttributes.self) { context in
            NextEventLockScreenView(state: context.state, label: context.attributes.label)
                .activityBackgroundTint(Color("WidgetBackground"))
                .activitySystemActionForegroundColor(museyBlue)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.emptyDay ? "checkmark.circle" : "calendar")
                        .font(.title2)
                        .foregroundStyle(museyBlue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !state.emptyDay {
                        NextEventCountdown(state: state)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 90, alignment: .trailing)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.emptyDay {
                        Text(context.attributes.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(NextEventText.detail(state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: state.emptyDay ? "checkmark.circle" : "calendar")
                    .foregroundStyle(museyBlue)
            } compactTrailing: {
                if state.emptyDay {
                    Text("Free")
                        .font(.caption2.weight(.semibold))
                } else {
                    NextEventCountdown(state: state)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .frame(maxWidth: 48)
                }
            } minimal: {
                Image(systemName: state.emptyDay ? "checkmark.circle" : "calendar")
                    .foregroundStyle(museyBlue)
            }
            .keylineTint(museyBlue)
        }
    }
}

@available(iOS 16.1, *)
enum NextEventText {
    /// "9:30 AM · Work", or just the time.
    static func detail(_ state: NextEventAttributes.ContentState) -> String {
        guard let start = state.startDate else { return state.calendar }
        let time = start.formatted(date: .omitted, time: .shortened)
        return state.calendar.isEmpty ? time : "\(time) · \(state.calendar)"
    }
}

/// A live countdown to the start, or "Now" once it has begun.
@available(iOS 16.2, *)
struct NextEventCountdown: View {
    let state: NextEventAttributes.ContentState

    var body: some View {
        if let start = state.startDate, start > Date() {
            Text(timerInterval: Date()...start, countsDown: true)
        } else {
            Text("Now")
        }
    }
}

@available(iOS 16.2, *)
struct NextEventLockScreenView: View {
    let state: NextEventAttributes.ContentState
    let label: String
    @Environment(\.colorScheme) private var colorScheme

    private var primary: Color {
        colorScheme == .dark ? .white : Color(red: 0.08, green: 0.16, blue: 0.30)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state.emptyDay ? "checkmark.circle" : "calendar")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(museyBlue)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(primary.opacity(0.6))
                Text(state.emptyDay ? "Nothing else today" : state.title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(primary)
                    .lineLimit(2)
                if !state.emptyDay {
                    Text(NextEventText.detail(state))
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(primary.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !state.emptyDay {
                NextEventCountdown(state: state)
                    .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(museyBlue)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 96, alignment: .trailing)
            }
        }
        .padding(16)
    }
}
