import SwiftUI

struct LegalView: View {
    var body: some View {
        List {
            Section {
                Text(LegalContent.privacyPolicyBody)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Full privacy policy (web)", destination: LegalLinks.publicPrivacyPolicy)
                    .font(.subheadline)
            } header: {
                Text(LegalContent.privacyPolicyTitle)
                    .textCase(nil)
            }

            Section {
                ForEach(LegalContent.dataSources) { source in
                    VStack(alignment: .leading, spacing: 8) {
                        Link(source.title, destination: source.linkURL)
                            .font(.headline)
                        Text(source.attribution)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 4) {
                            Text("License:")
                                .foregroundStyle(.secondary)
                            if let licenseURL = source.licenseURL {
                                Link(source.licenseName, destination: licenseURL)
                            } else {
                                Text(source.licenseName)
                            }
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Data sources & licenses")
                    .textCase(nil)
            }
        }
        .navigationTitle("Legal & Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
