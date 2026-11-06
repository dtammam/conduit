//
//  ConduitWidget.swift
//  ConduitWidget
//
//  Created by cogwheel on 07/12/25.
//

import WidgetKit
import SwiftUI

private enum WidgetDeepLink {
    static var scheme: String {
        guard
            let configuredScheme = Bundle.main.object(forInfoDictionaryKey: "AppUrlScheme") as? String,
            !configuredScheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "conduit"
        }
        return configuredScheme
    }

    static func url(for action: String) -> URL {
        URL(string: "\(scheme)://\(action)?homeWidget=true")!
    }
}

// MARK: - Musey look

/// Musey's blue, the colour of the M in the app icon.
private let museyBlue = Color(red: 0.231, green: 0.576, blue: 0.980)

/// The Musey "M" (the app icon's mark), drawn as a rounded stroke so the
/// widget needs no image asset.
private struct MuseyMark: Shape {
    func path(in rect: CGRect) -> Path {
        // Control points are the icon's 1024 grid, scaled into rect.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + (x - 170) / 680 * rect.width,
                y: rect.minY + (y - 240) / 535 * rect.height
            )
        }
        var path = Path()
        path.move(to: p(245, 715))
        path.addCurve(to: p(340, 300), control1: p(215, 600), control2: p(215, 300))
        path.addCurve(to: p(512, 590), control1: p(440, 300), control2: p(440, 590))
        path.addCurve(to: p(685, 300), control1: p(585, 590), control2: p(585, 300))
        path.addCurve(to: p(780, 715), control1: p(810, 300), control2: p(810, 600))
        return path
    }
}

// MARK: - Timeline Entry

struct ConduitEntry: TimelineEntry {
    let date: Date
}

// MARK: - Timeline Provider

struct ConduitProvider: TimelineProvider {
    func placeholder(in context: Context) -> ConduitEntry {
        ConduitEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (ConduitEntry) -> Void) {
        let entry = ConduitEntry(date: Date())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ConduitEntry>) -> Void) {
        let entry = ConduitEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

// MARK: - Widget View

struct ConduitWidgetEntryView: View {
    var entry: ConduitProvider.Entry
    @Environment(\.widgetFamily) var family
    @Environment(\.colorScheme) var colorScheme

    /// Adaptive text/icon color based on color scheme
    private var contentColor: Color {
        colorScheme == .dark ? .white : Color(red: 0.08, green: 0.16, blue: 0.30)
    }

    /// Adaptive button background: a wash of Musey blue
    private var buttonBackground: Color {
        colorScheme == .dark
            ? museyBlue.opacity(0.22)
            : museyBlue.opacity(0.16)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Main pill: opens Omni with the action menu (the wrench).
            Link(destination: WidgetDeepLink.url(for: "actions")) {
                HStack(spacing: 12) {
                    MuseyMark()
                        .stroke(
                            museyBlue,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 28, height: 22)
                    Text("Ask Musey")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(contentColor.opacity(0.85))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    Capsule()
                        .fill(buttonBackground)
                )
            }
            .buttonStyle(.plain)

            // 4 circular icon buttons, fill width; every one lands in Omni
            HStack(spacing: 8) {
                CircularIconButton(
                    symbol: "camera",
                    destination: WidgetDeepLink.url(for: "camera"),
                    contentColor: contentColor,
                    buttonBackground: buttonBackground
                )
                CircularIconButton(
                    symbol: "photo.on.rectangle.angled",
                    destination: WidgetDeepLink.url(for: "photos"),
                    contentColor: contentColor,
                    buttonBackground: buttonBackground
                )
                CircularIconButton(
                    symbol: "waveform",
                    destination: WidgetDeepLink.url(for: "mic"),
                    contentColor: contentColor,
                    buttonBackground: buttonBackground
                )
                CircularIconButton(
                    symbol: "doc.on.clipboard",
                    destination: WidgetDeepLink.url(for: "clipboard"),
                    contentColor: contentColor,
                    buttonBackground: buttonBackground
                )
            }
        }
        .padding(16)
    }
}

// MARK: - Circular Icon Button 

struct CircularIconButton: View {
    let symbol: String
    let destination: URL
    let contentColor: Color
    let buttonBackground: Color

    var body: some View {
        Link(destination: destination) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(contentColor.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(buttonBackground)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Widget Configuration

struct ConduitWidget: Widget {
    let kind: String = "ConduitWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ConduitProvider()) { entry in
            if #available(iOS 17.0, *) {
                ConduitWidgetEntryView(entry: entry)
                    .containerBackground(Color("WidgetBackground"), for: .widget)
            } else {
                ConduitWidgetEntryView(entry: entry)
                    .background(Color("WidgetBackground"))
            }
        }
        .configurationDisplayName("Musey")
        .description("Open Omni with the action menu, voice, photos or camera.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Preview

struct ConduitWidget_Previews: PreviewProvider {
    static var previews: some View {
        ConduitWidgetEntryView(entry: ConduitEntry(date: Date()))
            .previewContext(WidgetPreviewContext(family: .systemMedium))
            .background(Color("WidgetBackground"))
    }
}

