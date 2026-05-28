import Foundation

enum LegalLinks {
    /// Hosted on GitHub Pages (`docs/`). Enable Pages in repo settings before App Store submission.
    static let publicPrivacyPolicy = URL(
        string: "https://thetoastykitten.github.io/word-a-day/privacy-policy.html"
    )!
    static let openRussian = URL(string: "https://en.openrussian.org/")!
    static let frequencyWords = URL(string: "https://github.com/hermitdave/FrequencyWords")!
    static let tatoebaDownloads = URL(string: "https://tatoeba.org/en/downloads")!
    static let ccBySa = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!
    static let ccBy20Fr = URL(string: "https://creativecommons.org/licenses/by/2.0/fr/")!
    static let mitLicense = URL(string: "https://opensource.org/licenses/MIT")!
}

enum LegalContent {
    static let privacyPolicyTitle = "Privacy Policy"

    static let privacyPolicyBody = """
    This app is an entirely offline Russian–English dictionary with optional push notifications. \
    It does not track your personal data across other apps or websites and does not collect any of \
    your personal information. All audio on the app is generated locally on your device via its own \
    text-to-speech features.
    """

    struct DataSource: Identifiable {
        let id: String
        let title: String
        let attribution: String
        let licenseName: String
        let licenseURL: URL?
        let linkURL: URL
    }

    static let dataSources: [DataSource] = [
        DataSource(
            id: "openrussian",
            title: "OpenRussian.org",
            attribution: "Dictionary data from OpenRussian.org contributors (definitions, usage notes, and bundled examples).",
            licenseName: "CC BY-SA 4.0",
            licenseURL: LegalLinks.ccBySa,
            linkURL: LegalLinks.openRussian
        ),
        DataSource(
            id: "tatoeba",
            title: "Tatoeba (example sentences)",
            attribution: "Additional example sentences from Tatoeba contributors where OpenRussian has none (text typically CC BY 2.0 FR).",
            licenseName: "CC BY 2.0 FR",
            licenseURL: LegalLinks.ccBy20Fr,
            linkURL: LegalLinks.tatoebaDownloads
        ),
        DataSource(
            id: "frequency",
            title: "Hermit Dave / FrequencyWords",
            attribution: "Frequency data: Hermit Dave, FrequencyWords (MIT).",
            licenseName: "MIT",
            licenseURL: LegalLinks.mitLicense,
            linkURL: LegalLinks.frequencyWords
        ),
    ]
}
