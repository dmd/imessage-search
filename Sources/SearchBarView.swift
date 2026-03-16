import SwiftUI

struct SearchBarView: View {
    @Bindable var state: AppState
    var onSearch: () -> Void
    var isSearchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 10) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search messages...", text: $state.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused(isSearchFocused)
                    .onSubmit { onSearch() }
            }
            .padding(10)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )

            // Filter row 1: Contact, Direction, Chat
            HStack(spacing: 8) {
                // Contact picker
                Picker("Contact", selection: $state.selectedContact) {
                    Text("Anyone").tag("")
                    let resolved = state.contactEntries.filter(\.isResolved)
                    let unresolved = state.contactEntries.filter { !$0.isResolved }
                    if !resolved.isEmpty {
                        Section("Contacts") {
                            ForEach(resolved) { c in
                                Text(c.name).tag(c.name)
                            }
                        }
                    }
                    if state.showUnknownContacts && !unresolved.isEmpty {
                        Section("Other (\(unresolved.count))") {
                            ForEach(unresolved) { c in
                                Text(c.name).tag(c.name)
                            }
                        }
                    }
                }
                .frame(maxWidth: 200)

                Toggle("Unknowns", isOn: $state.showUnknownContacts)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Spacer()

                // Direction
                Picker("Direction", selection: $state.direction) {
                    Text("All").tag("all")
                    Text("Sent").tag("sent")
                    Text("Received").tag("received")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Spacer()

                // Chat picker
                Picker("Chat", selection: $state.selectedChatIDString) {
                    Text("All chats").tag("")
                    let visible = state.showUnknownChats
                        ? state.chatEntries
                        : state.chatEntries.filter(\.isResolved)
                    let direct = visible.filter { !$0.isGroup }
                    let groups = visible.filter(\.isGroup)
                    if !direct.isEmpty {
                        Section("Direct Messages") {
                            ForEach(direct) { c in
                                Text("\(c.name) (\(c.messageCount))").tag(c.id)
                            }
                        }
                    }
                    if !groups.isEmpty {
                        Section("Group Chats") {
                            ForEach(groups) { c in
                                Text("\(c.name) (\(c.messageCount))").tag(c.id)
                            }
                        }
                    }
                }
                .frame(maxWidth: 200)

                Toggle("Unknowns", isOn: $state.showUnknownChats)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            // Filter row 2: Dates + Regex
            HStack(spacing: 8) {
                Text("From")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("YYYY-MM-DD", text: $state.dateFrom)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)

                Text("To")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("YYYY-MM-DD", text: $state.dateTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)

                Spacer()

                Toggle("Regex", isOn: $state.useRegex)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}
