import SwiftUI

/// Your topics as tappable bubbles, grouped by section, like Apple News and Particle's pickers.
/// The same picks drive For you on Today and in News.
struct TopicChips: View {
    @EnvironmentObject private var store: NewsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Topic.allCases) { section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.pickerTitle).scoutLabel()
                    FlowLayout(spacing: 8) {
                        ForEach(section.interests, id: \.self) { t in
                            Chip(title: t, on: store.interests.contains(t)) {
                                if store.interests.contains(t) { store.interests.remove(t) } else { store.interests.insert(t) }
                            }
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: store.interests)
    }
}

/// Where your world and market news comes from.
struct RegionChips: View {
    @EnvironmentObject private var store: NewsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("World and market news from").scoutLabel()
            FlowLayout(spacing: 8) {
                ForEach(NewsStore.allRegions, id: \.self) { r in
                    Chip(title: Self.title(r), on: store.regions.contains(r)) {
                        // always at least one region
                        if store.regions.contains(r) { if store.regions.count > 1 { store.regions.remove(r) } }
                        else { store.regions.insert(r) }
                    }
                }
            }
            Text("Stories that matter worldwide always show.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
        }
        .sensoryFeedback(.selection, trigger: store.regions)
    }

    static func title(_ region: String) -> String { region }
}

/// One bubble: plain when off, filled in the main color with a tick when on.
struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { action() }
        } label: {
            HStack(spacing: 5) {
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(on ? Theme.ink : Theme.card, in: Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : Theme.hairline, lineWidth: 1))
            .foregroundStyle(on ? Theme.background : Theme.text)
        }
        .buttonStyle(PressStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Your topics and regions on one page, pushed from Settings or inside TopicsSheet.
struct TopicsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your topics").font(.system(size: 26, weight: .semibold)).tracking(-0.3).foregroundStyle(Theme.text)
                    Text("For you on Today and in News follows these, with the day's biggest stories mixed in.")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                }
                TopicChips()
                RegionChips()
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The same page as a sheet, from Today and News.
struct TopicsSheet: View {
    @EnvironmentObject private var store: NewsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TopicsPage()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .tint(Theme.ink)
        }
        .environmentObject(store)
    }
}

extension Topic {
    /// The group heading in the topic picker.
    var pickerTitle: String {
        switch self {
        case .tech: return "Tech"
        case .finance: return "Money"
        case .world: return "World"
        case .fashion: return "Style"
        }
    }
}
