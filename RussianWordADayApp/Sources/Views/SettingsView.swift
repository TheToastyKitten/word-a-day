import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WordStore
    @EnvironmentObject private var scheduler: WordADayScheduler
    @EnvironmentObject private var router: AppRouter

    @State private var showExhaustedAlert = false
    @State private var showDeniedAlert = false
    @State private var showAppliedAlert = false
    @State private var showQuizDirectionPicker = false
    @State private var pendingQuizSource: QuizSource?
    @State private var isApplying = false

    var body: some View {
        Form {
            Section {
                PronunciationSpeedControl(
                    value: Binding(
                        get: { settings.pronunciationRateScale },
                        set: { settings.pronunciationRateScale = AppSettings.snapPronunciationRateScale($0) }
                    )
                )
            } header: {
                Text("Pronunciation")
            }

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
                NavigationLink(value: AppRoute.usedWords) {
                    Text("Manage already pushed words")
                }

                Button {
                    pendingQuizSource = .pushed
                    showQuizDirectionPicker = true
                } label: {
                    Text("Quiz yourself on already pushed words")
                }
                .disabled(store.usedWordCount() < 1)

                Button {
                    pendingQuizSource = .favorites
                    showQuizDirectionPicker = true
                } label: {
                    Text("Quiz yourself on favourited words")
                }
                .disabled(store.favoriteWordCount() < 1)
            }

            Section("Legal & privacy") {
                NavigationLink(value: AppRoute.legal) {
                    Text("Data sources, licenses & privacy")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("No words remaining", isPresented: $showExhaustedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You’ve used every word in the offline dictionary. Reset pushed words to start over.")
        }
        .alert("Notifications not available", isPresented: $showDeniedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Notifications are denied or couldn’t be scheduled. Check Settings → Notifications for this app.")
        }
        .alert("Schedule successfully updated!", isPresented: $showAppliedAlert) {
            Button("OK", role: .cancel) {}
        }
        .alert("Choose quiz type", isPresented: $showQuizDirectionPicker) {
            Button(QuizDirection.russianToEnglish.title) {
                guard let source = pendingQuizSource else { return }
                router.path.append(.quiz(source: source, direction: .russianToEnglish))
            }
            Button(QuizDirection.englishToRussian.title) {
                guard let source = pendingQuizSource else { return }
                router.path.append(.quiz(source: source, direction: .englishToRussian))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Which direction do you want to practice?")
        }
        .onChange(of: showQuizDirectionPicker) { _, isShowing in
            if !isShowing {
                pendingQuizSource = nil
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
            showAppliedAlert = true
        } catch {
            showDeniedAlert = true
        }
    }

    private func dateForSeconds(_ seconds: Int) -> Date {
        let hour = seconds / 3600
        let minute = (seconds % 3600) / 60
        return Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
    }
}
