import SwiftUI

struct ContentView: View {
    @State var state = AppState()
    @FocusState private var isSearchFocused: Bool
    @State private var showFilters = false

    var body: some View {
        Group {
            switch state.loadState {
            case .loading(let status):
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(status)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .permissionDenied:
                PermissionsView()

            case .error(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("Failed to load")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(msg)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready:
                VStack(spacing: 0) {
                    VStack(spacing: 4) {
                        // Row 1: Search field + contact + chat pickers
                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(.tertiary)
                                    .font(.system(size: 12))
                                TextField("Search messages...", text: $state.searchQuery)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .focused($isSearchFocused)
                                    .onSubmit { state.performSearch() }
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            .background(Color(.controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

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
                            .frame(width: 160)
                            .controlSize(.small)

                            Picker("Chat", selection: $state.selectedChatIDString) {
                                Text("All chats").tag("")
                                let visible = state.showUnknownChats
                                    ? state.chatEntries
                                    : state.chatEntries.filter(\.isResolved)
                                let direct = visible.filter { !$0.isGroup }
                                let groups = visible.filter(\.isGroup)
                                if !direct.isEmpty {
                                    Section("Direct") {
                                        ForEach(direct) { c in
                                            Text("\(c.name) (\(c.messageCount))").tag(c.id)
                                        }
                                    }
                                }
                                if !groups.isEmpty {
                                    Section("Groups") {
                                        ForEach(groups) { c in
                                            Text("\(c.name) (\(c.messageCount))").tag(c.id)
                                        }
                                    }
                                }
                            }
                            .frame(width: 160)
                            .controlSize(.small)

                            Picker("", selection: $state.direction) {
                                Text("All").tag("all")
                                Text("Sent").tag("sent")
                                Text("Received").tag("received")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 150)
                            .controlSize(.small)
                        }

                        // Row 2: Dates, regex, unknowns, stats
                        HStack(spacing: 8) {
                            Text("From")
                                .foregroundStyle(.secondary)
                            TextField("YYYY-MM-DD", text: $state.dateFrom)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)

                            Text("To")
                                .foregroundStyle(.secondary)
                            TextField("YYYY-MM-DD", text: $state.dateTo)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)

                            Divider().frame(height: 14)

                            Toggle("Regex", isOn: $state.useRegex)
                                .toggleStyle(.checkbox)

                            Divider().frame(height: 14)

                            Toggle("Unknown contacts", isOn: $state.showUnknownContacts)
                                .toggleStyle(.checkbox)

                            Toggle("Unknown chats", isOn: $state.showUnknownChats)
                                .toggleStyle(.checkbox)

                            Spacer(minLength: 0)

                            Text(state.statsLine)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.bar)

                    Divider()

                    // Scrollable results
                    ResultsView(state: state)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear { state.load() }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) && event.characters == "f" {
                    isSearchFocused = true
                    return nil
                }
                return event
            }
        }
    }
}
