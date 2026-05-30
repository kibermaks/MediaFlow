import AppKit
import SwiftUI

struct MediaFlowWhatsNewView: View {
    @ObservedObject var changelog: MediaFlowChangelogService
    let onClose: () -> Void
    let onOpenGitHub: () -> Void

    private var entries: [MediaFlowChangelogEntry] {
        changelog.entries
    }

    var body: some View {
        ZStack {
            MediaFlowWhatsNewColors.background
                .ignoresSafeArea()
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                content
            }
        }
        .frame(minWidth: 500, minHeight: 430)
        .onAppear {
            changelog.fetchIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let image = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 42, height: 42)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("What's New")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(MediaFlowWhatsNewColors.primaryText)
                Text("\(AppMetadata.name) v\(MediaFlowChangelogService.currentVersion)")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(MediaFlowWhatsNewColors.secondaryText)
            }

            Spacer(minLength: 12)

            Button(action: onOpenGitHub) {
                Label("Open on GitHub", systemImage: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(FlowPillButtonStyle(isAccent: false))
            .help("Open CHANGELOG.md on GitHub")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(FlowIconButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close")
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var content: some View {
        if changelog.isLoading && entries.isEmpty {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Loading changelog...")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MediaFlowWhatsNewColors.secondaryText)
                .padding(.top, 8)
            Spacer()
        } else if entries.isEmpty {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(MediaFlowWhatsNewColors.tertiaryText)
            Text("No changelog available")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MediaFlowWhatsNewColors.secondaryText)
                .padding(.top, 8)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(entries, id: \.version) { entry in
                        versionBlock(entry)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func versionBlock(_ entry: MediaFlowChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("v\(entry.version)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(MediaFlowWhatsNewColors.primaryText)

                if !entry.date.isEmpty {
                    Text(entry.date)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(MediaFlowWhatsNewColors.tertiaryText)
                }

                Spacer()
            }

            ForEach(entry.sections, id: \.category) { section in
                sectionBlock(section)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(MediaFlowWhatsNewColors.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(MediaFlowWhatsNewColors.divider, lineWidth: 1)
                )
        )
    }

    private func sectionBlock(_ section: MediaFlowChangelogEntry.Section) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: iconForCategory(section.category))
                    .font(.system(size: 11, weight: .semibold))
                Text(section.category)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(colorForCategory(section.category))

            VStack(alignment: .leading, spacing: 5) {
                ForEach(section.items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(MediaFlowWhatsNewColors.tertiaryText)
                            .padding(.top, 1)
                        Text(item)
                            .font(.system(size: 13, weight: .regular))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(MediaFlowWhatsNewColors.secondaryText)
                    }
                }
            }
        }
    }

    private func iconForCategory(_ category: String) -> String {
        switch category.lowercased() {
        case "added": return "plus.circle.fill"
        case "changed": return "arrow.triangle.2.circlepath"
        case "fixed": return "wrench.and.screwdriver.fill"
        case "removed": return "minus.circle.fill"
        case "deprecated": return "exclamationmark.triangle.fill"
        case "security": return "lock.shield.fill"
        default: return "circle.fill"
        }
    }

    private func colorForCategory(_ category: String) -> Color {
        switch category.lowercased() {
        case "added": return MediaFlowWhatsNewColors.accent
        case "changed": return MediaFlowWhatsNewColors.accentBlue
        case "fixed": return Color(red: 0.96, green: 0.70, blue: 0.30)
        case "removed": return Color(red: 0.96, green: 0.40, blue: 0.40)
        case "deprecated": return Color(red: 0.96, green: 0.55, blue: 0.28)
        case "security": return Color(red: 0.70, green: 0.55, blue: 0.98)
        default: return MediaFlowWhatsNewColors.secondaryText
        }
    }
}

private enum MediaFlowWhatsNewColors {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.17, green: 0.13, blue: 0.14),
            Color(red: 0.18, green: 0.09, blue: 0.05)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let cardFill = Color(red: 0.27, green: 0.18, blue: 0.14).opacity(0.78)
    static let controlFill = Color(red: 0.34, green: 0.26, blue: 0.22).opacity(0.86)
    static let accent = Color(red: 0.16, green: 0.92, blue: 0.72)
    static let accentBlue = Color(red: 0.20, green: 0.78, blue: 0.88)
    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.38)
    static let divider = Color.white.opacity(0.10)
}

private struct FlowPillButtonStyle: ButtonStyle {
    let isAccent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isAccent ? Color.black.opacity(0.86) : MediaFlowWhatsNewColors.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background { buttonBackground }
            .opacity(configuration.isPressed ? 0.82 : 1)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        if isAccent {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    LinearGradient(
                        colors: [MediaFlowWhatsNewColors.accent, MediaFlowWhatsNewColors.accentBlue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        } else {
            RoundedRectangle(cornerRadius: 7)
                .fill(MediaFlowWhatsNewColors.controlFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(MediaFlowWhatsNewColors.divider, lineWidth: 1)
                )
        }
    }
}

private struct FlowIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(MediaFlowWhatsNewColors.secondaryText)
            .background(
                Circle()
                    .fill(MediaFlowWhatsNewColors.controlFill)
                    .overlay(Circle().strokeBorder(MediaFlowWhatsNewColors.divider, lineWidth: 1))
            )
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}
