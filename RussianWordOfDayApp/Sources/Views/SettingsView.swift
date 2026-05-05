import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WordStore
    @EnvironmentObject private var scheduler: WordOfDayScheduler

    @State private var showExhaustedAlert = false
    @State private var showDeniedAlert = false
    @State private var showAppliedAlert = false
    @State private var lastAppliedCount = 0
    @State private var lastBufferCount = 0
    @State private var isApplying = false

    var body: some View {
        Form {
            Section("Notifications") {
                Stepper(value: $settings.pushCountPerDay, in: 1...5) {
                    Text("Pushes per day: \(settings.pushCountPerDay)")
                }
                .onChange(of: settings.pushCountPerDay) { _, _ in
                    settings.normalizeTimesToPushCount()
                }

                ForEach(0..<settings.pushTimesSeconds.count, id: \.self) { idx in
                    DatePicker(
                        "Push time \(idx + 1)",
                        selection: Binding(
                            get: { dateForSeconds(settings.pushTimesSeconds[idx]) },
                            set: { newDate in
                                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                settings.setTime(at: idx, hour: comps.hour ?? 9, minute: comps.minute ?? 0)
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                }

                Button {
                    Task { await applySchedule() }
                } label: {
                    HStack {
                        Text("Apply notification schedule")
                        if isApplying {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isApplying)
            }

            Section("Dictionary") {
                Button(role: .destructive) {
                    Task { await resetUsedWords() }
                } label: {
                    Text("Reset already used words")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("No words remaining", isPresented: $showExhaustedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You’ve used every word in the offline dictionary. Reset used words to start over.")
        }
        .alert("Notifications not available", isPresented: $showDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Notifications are denied or couldn’t be scheduled. Check Settings → Notifications for this app.")
        }
        .alert("Schedule updated", isPresented: $showAppliedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if lastAppliedCount > 0 {
                Text("Queued \(lastAppliedCount) new notification\(lastAppliedCount == 1 ? "" : "s"). Buffer now contains \(lastBufferCount) upcoming push\(lastBufferCount == 1 ? "" : "es").")
            } else {
                Text("Buffer is up to date with \(lastBufferCount) upcoming push\(lastBufferCount == 1 ? "" : "es").")
            }
        }
    }

    private func applySchedule() async {
        isApplying = true
        defer { isApplying = false }
        do {
            // The user's timing/count may have changed since the last buffer
            // was built — rebuild from scratch so old fire times don't linger.
            let result = try await scheduler.rebuildAfterSettingsChange(
                settings: settings,
                store: store
            )
            if result.bufferCount == 0 && result.exhausted {
                showExhaustedAlert = true
                return
            }
            lastAppliedCount = result.addedCount
            lastBufferCount = result.bufferCount
            showAppliedAlert = true
        } catch {
            showDeniedAlert = true
        }
    }

    private func resetUsedWords() async {
        store.resetUsedWords()
        await scheduler.purgeAfterReset()
    }

    private func dateForSeconds(_ seconds: Int) -> Date {
        let hour = seconds / 3600
        let minute = (seconds % 3600) / 60
        return Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
    }
}
