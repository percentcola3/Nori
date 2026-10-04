import SwiftUI
import AppKit

private enum ClipboardResourceColors {
    static let text = Color.blue
    static let url = Color.teal
    static let file = Color.orange
    static let image = Color.purple
}

struct ClipboardHistoryTabView: View {
    @ObservedObject var manager: ClipboardHistoryManager
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all, pinned, text, url, file, image
        var id: String { rawValue }
        var titleKey: String { "clip.filter.\(rawValue)" }

        var icon: String {
            switch self {
            case .all: "square.grid.2x2"
            case .pinned: "pin.fill"
            case .text: "doc.plaintext"
            case .url: "link"
            case .file: "doc"
            case .image: "photo"
            }
        }

        var iconTint: Color {
            switch self {
            case .all: Color.moleAccentText
            case .pinned: Color.warning
            case .text: ClipboardResourceColors.text
            case .url: ClipboardResourceColors.url
            case .file: ClipboardResourceColors.file
            case .image: ClipboardResourceColors.image
            }
        }
    }

    private var filteredEntries: [ClipboardHistoryManager.Entry] {
        switch filter {
        case .all: manager.entries
        case .pinned: manager.entries.filter(\.isPinned)
        case .text: manager.entries.filter { $0.kind == .text }
        case .url: manager.entries.filter { $0.kind == .url }
        case .file: manager.entries.filter { $0.kind == .file }
        case .image: manager.entries.filter { $0.kind == .image }
        }
    }

    private var capacityBinding: Binding<Int> {
        Binding(
            get: { manager.capacity },
            set: { manager.updateCapacity($0) })
    }

    private var capacityOptions: [Int] {
        Array(Set([10, 20, 40, 50, 100, 200, 500, manager.capacity])).sorted()
    }

    private var capacityControl: some View {
        Menu {
            Picker(selection: capacityBinding) {
                ForEach(capacityOptions, id: \.self) { value in
                    Text(l10n.tf("clip.capacity", value)).tag(value)
                }
            } label: {
                Text(l10n.t("clip.capacityLabel"))
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(l10n.tf("clip.capacity", manager.capacity))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.hairline))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(l10n.t("clip.capacityLabel"))
        .accessibilityValue(l10n.tf("clip.capacity", manager.capacity))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases) { item in
                            Button {
                                if reduceMotion {
                                    filter = item
                                } else {
                                    withAnimation(MoleMotion.selection) { filter = item }
                                }
                            } label: {
                                Label {
                                    Text(l10n.t(item.titleKey))
                                } icon: {
                                    Image(systemName: item.icon)
                                        .foregroundStyle(item.iconTint)
                                }
                            }
                            .buttonStyle(ClipboardFilterButtonStyle(isSelected: filter == item))
                        }
                    }
                }
                .layoutPriority(1)

                Spacer()

                capacityControl

                Button {
                    manager.clearUnpinned()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(MoleIconButtonStyle(tint: Color.danger, size: 30))
                .help(l10n.t("clip.clearUnpinned"))
                .accessibilityLabel(l10n.t("clip.clearUnpinned"))
                .disabled(manager.unpinnedCount == 0)
            }

            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: filter == .all ? "clipboard" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(l10n.t(filter == .all ? "clip.empty" : "clip.filter.empty"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)],
                              alignment: .leading, spacing: 10) {
                        ForEach(filteredEntries) { entry in
                            ClipboardHistoryCard(
                                entry: entry,
                                onCopy: { manager.copyToPasteboard(entry) },
                                onTogglePin: { manager.togglePinned(entry.id) },
                                onDelete: { manager.remove(entry.id) }
                            )
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

private struct ClipboardFilterButtonStyle: ButtonStyle {
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isSelected ? Color.moleAccentText : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                Capsule().fill(isSelected
                    ? Color.moleAccent.opacity(configuration.isPressed ? 0.24 : 0.17)
                    : (configuration.isPressed ? Color.surface3 : Color.surface2))
            )
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .animation(reduceMotion ? nil : MoleMotion.press,
                       value: configuration.isPressed)
    }
}

private struct ClipboardHistoryCard: View {
    let entry: ClipboardHistoryManager.Entry
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 140,
                       alignment: entry.kind == .image ? .center : .topLeading)
                .clipped()
                .padding(10)

            footer
        }
        .frame(height: 194, alignment: .topLeading)
        .modifier(ListRowSurface(selected: entry.isPinned))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(reduceMotion ? nil : MoleMotion.selection, value: entry.isPinned)
        .animation(reduceMotion ? nil : MoleMotion.press, value: copied)
        .task(id: copied) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(1.2))
                copied = false
            } catch { }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Image(systemName: kindIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(kindTint)
                .fixedSize()
                .help(l10n.t(kindTitleKey))
                .accessibilityLabel(l10n.t(kindTitleKey))

            Spacer(minLength: 6)

            Button {
                onCopy()
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(MoleIconButtonStyle(isActive: copied,
                                            tint: copied ? Color.success : Color.moleAccentText,
                                            size: 24, showsBackground: copied))
            .help(l10n.t(copied ? "shot.copied" : "clip.copy"))
            .accessibilityLabel(l10n.t(copied ? "shot.copied" : "clip.copy"))

            Button(action: onTogglePin) {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(MoleIconButtonStyle(isActive: entry.isPinned, size: 24,
                                            showsBackground: entry.isPinned))
            .help(l10n.t(entry.isPinned ? "clip.unpin" : "clip.pin"))
            .accessibilityLabel(l10n.t(entry.isPinned ? "clip.unpin" : "clip.pin"))
            .accessibilityAddTraits(entry.isPinned ? .isSelected : [])

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(MoleIconButtonStyle(size: 24, showsBackground: false))
            .help(l10n.t("clip.delete"))
            .accessibilityLabel(l10n.t("clip.delete"))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.surface2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.hairline)
                .frame(height: 1 / max(displayScale, 1))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .image:
            if let data = entry.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(l10n.t("clip.imageUnavailable"))
                    .foregroundStyle(.tertiary)
            }
        case .file:
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                    .joined(separator: ", "))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                Text(entry.filePaths.joined(separator: "\n"))
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        case .url:
            Text(entry.text ?? "")
                .font(.system(size: 13).monospaced())
                .foregroundStyle(Color.moleAccentText)
                .lineSpacing(3)
                .lineLimit(6)
        case .text:
            ScrollView(.vertical) {
                Text(entry.text ?? "")
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(.primary)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.trailing, 4)
            }
        }
    }

    private var kindTitleKey: String { "clip.kind.\(entry.kind.rawValue)" }

    private var kindIcon: String {
        switch entry.kind {
        case .text: "doc.plaintext"
        case .url: "link"
        case .file: "doc"
        case .image: "photo"
        }
    }

    private var kindTint: Color {
        switch entry.kind {
        case .text: ClipboardResourceColors.text
        case .url: ClipboardResourceColors.url
        case .file: ClipboardResourceColors.file
        case .image: ClipboardResourceColors.image
        }
    }
}
