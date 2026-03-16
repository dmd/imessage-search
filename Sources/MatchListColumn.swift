import SwiftUI

struct MatchListColumn: View {
    let matches: [MessageMatch]
    let selectedMatch: MessageMatch?
    let chatName: String
    let onSelect: (MessageMatch) -> Void

    var body: some View {
        if matches.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Select a chat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(chatName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(matches.count) matches")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)

                Divider()

                List(matches, selection: Binding<MessageMatch.ID?>(
                    get: { selectedMatch?.id },
                    set: { newID in
                        if let newID, let match = matches.first(where: { $0.id == newID }) {
                            onSelect(match)
                        }
                    }
                )) { match in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(match.sender)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            if let date = match.date {
                                Text(date)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(match.snippet)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 3)
                    .tag(match.id)
                }
                .listStyle(.plain)
            }
        }
    }
}
