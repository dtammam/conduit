//
//  MuseyActionsWidget.swift
//  ConduitWidget
//
//  "Musey Actions": a grid of filled, rounded tiles in the look of the iOS
//  Shortcuts widget. Each tile is a Link that opens Musey's Omni chat straight
//  on one action (its form or pick list), so one tap on the home screen lands
//  on the card flow. The list is fixed here because WidgetKit cannot fetch the
//  relay's catalog; a new relay action is reached through the More tile.
//

import WidgetKit
import SwiftUI

// MARK: - Tiles

struct MuseyTile: Identifiable {
    /// Catalog id on the relay, or nil for More (the plain wrench menu).
    let actionId: String?
    let short: String
    let full: String
    let symbol: String
    let color: Color

    var id: String { actionId ?? "more" }

    var url: URL {
        if let actionId { return WidgetDeepLink.url(forAction: actionId) }
        return WidgetDeepLink.url(for: "actions")
    }
}

/// Order matters: reading order in the 5x2 medium grid and the 2x5 large one.
/// Undo is deliberately not here: it acts at once with no card, so a stray tap
/// on the home screen would undo a real thing. It stays in More.
let museyTiles: [MuseyTile] = [
    MuseyTile(actionId: "home_control", short: "House", full: "Control the house",
              symbol: "house", color: Color(red: 0.98, green: 0.50, blue: 0.15)),
    MuseyTile(actionId: "chore_log", short: "Chore", full: "Log a chore",
              symbol: "checkmark.circle", color: Color(red: 0.20, green: 0.70, blue: 0.38)),
    MuseyTile(actionId: "expense_log", short: "Expense", full: "Log an expense",
              symbol: "dollarsign.circle", color: Color(red: 0.05, green: 0.64, blue: 0.64)),
    MuseyTile(actionId: "grocery_add", short: "Grocery", full: "Add to a grocery list",
              symbol: "cart.badge.plus", color: Color(red: 0.20, green: 0.58, blue: 0.92)),
    MuseyTile(actionId: "grocery_run", short: "Run", full: "Start a grocery run",
              symbol: "cart", color: Color(red: 0.38, green: 0.38, blue: 0.88)),
    MuseyTile(actionId: "event_create", short: "Calendar", full: "Add to the calendar",
              symbol: "calendar.badge.plus", color: Color(red: 0.90, green: 0.27, blue: 0.30)),
    MuseyTile(actionId: "note_quick", short: "Note", full: "Quick note",
              symbol: "note.text", color: Color(red: 0.86, green: 0.62, blue: 0.05)),
    MuseyTile(actionId: "routine_start", short: "Routine", full: "Run a routine",
              symbol: "play.circle", color: Color(red: 0.62, green: 0.36, blue: 0.88)),
    MuseyTile(actionId: "routine_done", short: "Check off", full: "Check off a routine",
              symbol: "checkmark.square", color: Color(red: 0.90, green: 0.34, blue: 0.60)),
    MuseyTile(actionId: nil, short: "More", full: "All actions",
              symbol: "square.grid.2x2", color: Color(red: 0.44, green: 0.46, blue: 0.52)),
]

// MARK: - View

struct MuseyActionsEntryView: View {
    var entry: ConduitProvider.Entry
    @Environment(\.widgetFamily) var family
    @Environment(\.colorScheme) var colorScheme

    private var large: Bool { family == .systemLarge }

    var body: some View {
        GeometryReader { geo in
            let columns = large ? 2 : 5
            let rows = large ? 5 : 2
            let pad: CGFloat = large ? 12 : 10
            let gap: CGFloat = large ? 8 : 6
            let tileW = max(1, (geo.size.width - 2 * pad - CGFloat(columns - 1) * gap) / CGFloat(columns))
            let tileH = max(1, (geo.size.height - 2 * pad - CGFloat(rows - 1) * gap) / CGFloat(rows))

            VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<columns, id: \.self) { c in
                            let i = r * columns + c
                            if i < museyTiles.count {
                                MuseyTileView(
                                    tile: museyTiles[i],
                                    large: large,
                                    dark: colorScheme == .dark,
                                    width: tileW,
                                    height: tileH
                                )
                            }
                        }
                    }
                }
            }
            .padding(pad)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Empty background: open Musey as it was, like the other widget.
        .widgetURL(WidgetDeepLink.url(for: "open"))
    }
}

struct MuseyTileView: View {
    let tile: MuseyTile
    let large: Bool
    let dark: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        // Sizes follow the tile so nothing clips on the smallest phone.
        let icon: CGFloat = large ? min(22, height * 0.38) : min(20, height * 0.36)
        let label: CGFloat = large ? min(14, height * 0.27) : 11
        let inset: CGFloat = large ? 10 : 6

        Link(destination: tile.url) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: tile.symbol)
                    .font(.system(size: icon, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Text(large ? tile.full : tile.short)
                    .font(.system(size: label, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            .padding(inset)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: large ? 16 : 14, style: .continuous)
                    .fill(tile.color.opacity(dark ? 0.86 : 1.0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Widget Configuration

struct MuseyActionsWidget: Widget {
    let kind: String = "MuseyActionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ConduitProvider()) { entry in
            if #available(iOS 17.0, *) {
                MuseyActionsEntryView(entry: entry)
                    .containerBackground(Color("WidgetBackground"), for: .widget)
            } else {
                MuseyActionsEntryView(entry: entry)
                    .background(Color("WidgetBackground"))
            }
        }
        .configurationDisplayName("Musey Actions")
        .description("One tap on an action: control the house, log a chore or an expense, groceries, notes and routines.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview

struct MuseyActionsWidget_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            MuseyActionsEntryView(entry: ConduitEntry(date: Date()))
                .previewContext(WidgetPreviewContext(family: .systemMedium))
            MuseyActionsEntryView(entry: ConduitEntry(date: Date()))
                .previewContext(WidgetPreviewContext(family: .systemLarge))
        }
        .background(Color("WidgetBackground"))
    }
}
