import SwiftUI

/// Stories you've bookmarked, kept even after they leave the news.
struct SavedView: View {
    @EnvironmentObject private var store: NewsStore
    @Binding var showSettings: Bool
    @State private var editing = false

    var body: some View {
        NavigationStack {
            ScoutPage(showSettings: $showSettings, title: "Saved",
                      subtitle: "\(store.saved.count) stor\(store.saved.count == 1 ? "y" : "ies")",
                      editing: store.saved.isEmpty ? nil : $editing) {
                if store.saved.isEmpty {
                    EmptyCard(symbol: "bookmark", title: "Nothing saved yet",
                              text: "Tap the bookmark at the top of any story to keep it here.")
                } else {
                    let seq = store.saved.map(\.id)
                    VStack(spacing: 0) {
                        ForEach(store.saved) { s in
                            HStack(spacing: 0) {
                                if editing {
                                    Button { withAnimation(.snappy) { store.unsave(s.id) } } label: {
                                        Image(systemName: "minus")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(Theme.background)
                                            .frame(width: 24, height: 24)
                                            .background(Theme.accent, in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.leading, 14)
                                    .transition(.scale.combined(with: .opacity))
                                    .accessibilityLabel("Remove")
                                }
                                NavigationLink(value: StoryRoute(id: s.id, sequence: seq)) { StoryRow(story: s) }
                                    .buttonStyle(PressStyle())
                                    .disabled(editing)
                            }
                            if s.id != store.saved.last?.id {
                                Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 16)
                            }
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .storyDestinations()
            .onChange(of: store.saved.isEmpty) { _, empty in if empty { editing = false } }
            .sensoryFeedback(.impact(weight: .light), trigger: store.saved.count)
        }
    }
}
