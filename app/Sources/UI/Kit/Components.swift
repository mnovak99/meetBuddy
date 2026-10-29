import SwiftUI

/// A rounded container with a subtle background: the building block of the panel and the dashboard.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.padding
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

/// A small coloured capsule with a word ("Hotovo", "Nahrávám").
struct StatusBadge: View {
    var text: String
    var tone: Tone

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone.color.opacity(0.15), in: Capsule())
            .foregroundStyle(tone.color)
    }
}

/// A coloured dot, e.g. for live signals (audio, microphone).
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// Icon + short text, for metrics in a row ("● zvuk", "7 snímků").
struct MetricPill: View {
    var symbolName: String
    var text: String
    var tone: Tone = .neutral

    var body: some View {
        Label(text, systemImage: symbolName)
            .font(.caption)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
    }
}

/// A warning or information strip with an optional action button.
struct Banner: View {
    var tone: Tone
    var title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.symbolName)
                .foregroundStyle(tone.color)
                .font(.body)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            // Wrap long texts instead of truncating them; the button keeps its full title.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        .padding(12)
        .background(tone.color.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }
}

/// A symbol in a tinted circle, for list rows and headers.
struct IconCircle: View {
    var symbolName: String
    var tone: Tone = .info
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(tone.color)
            .frame(width: size, height: size)
            .background(tone.color.opacity(0.12), in: Circle())
    }
}

/// Section title with an optional trailing view (count, button).
struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            trailing()
        }
    }
}

/// Label on the left, value on the right, for metadata lists.
struct KeyValueRow: View {
    var key: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

/// A single health or permission row: icon, title, detail and the action for its state.
struct HealthRow: View {
    var item: HealthItem
    var action: (HealthItem.Action) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconCircle(symbolName: item.symbolName, tone: item.state.tone, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.medium))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            if let title = item.actionTitle, let itemAction = item.action {
                Button(title) { action(itemAction) }
                    .controlSize(.small)
            } else {
                Image(systemName: item.state.tone.symbolName)
                    .foregroundStyle(item.state.tone.color)
            }
        }
        .padding(.vertical, 4)
    }
}
