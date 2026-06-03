import Foundation
import SwiftUI

// MARK: - Decoded payload (from `forms_json` in dictionary.sqlite)

struct WordFormsPayload: Decodable, Equatable {
    let title: String
    let note: String?
    let blocks: [WordFormsBlock]?
    let table: WordFormsTable?
}

struct WordFormsBlock: Decodable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let rows: [WordFormsRow]
}

struct WordFormsRow: Decodable, Equatable, Identifiable {
    var id: String { "\(label)|\(value)" }
    let label: String
    let value: String
}

struct WordFormsTable: Decodable, Equatable {
    let columns: [String]
    let rows: [WordFormsTableRow]
}

struct WordFormsTableRow: Decodable, Equatable, Identifiable {
    var id: String { label }
    let label: String
    let cells: [String]
}

enum WordFormsDecoder {
    static func decode(from json: String?) -> WordFormsPayload? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(WordFormsPayload.self, from: data)
    }
}

// MARK: - UI

struct WordFormsSectionView: View {
    @EnvironmentObject private var store: WordStore

    let payload: WordFormsPayload
    let currentWordID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(payload.title)
                .font(.headline)

            if let note = payload.note?.trimmingCharacters(in: .whitespacesAndNewlines),
               !note.isEmpty
            {
                Text(linkedFormsNote(note))
                    .font(.subheadline)
            }

            if let blocks = payload.blocks, !blocks.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(blocks) { block in
                        formsBlockView(block)
                    }
                }
            }

            if let table = payload.table {
                declensionTableView(table)
            }
        }
        .padding(.top, 4)
    }

    /// Renders notes like `imperfective aspect · partner смочь`, linking the partner lemma.
    private func linkedFormsNote(_ note: String) -> AttributedString {
        let preferredPOS = store.getWord(id: currentWordID)?.pos
        var result = AttributedString()
        let parts = note.components(separatedBy: " · ")
        let partnerPrefix = "partner "

        for (index, part) in parts.enumerated() {
            if index > 0 {
                result += secondaryFragment(" · ")
            }
            if part.hasPrefix(partnerPrefix) {
                let partnerText = String(part.dropFirst(partnerPrefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result += secondaryFragment(partnerPrefix)
                let tokens = partnerText.split(separator: ";", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                for (tokenIndex, token) in tokens.enumerated() {
                    if tokenIndex > 0 {
                        result += secondaryFragment(";")
                    }
                    result += partnerLemmaFragment(token, preferredPOS: preferredPOS)
                }
            } else {
                result += secondaryFragment(part)
            }
        }
        return result
    }

    private func partnerLemmaFragment(_ lemma: String, preferredPOS: String?) -> AttributedString {
        guard !lemma.isEmpty else { return AttributedString() }
        if let id = store.findWordID(
            russianHeadword: lemma,
            excludingID: currentWordID,
            preferredPOS: preferredPOS
        ) {
            var link = AttributedString(lemma)
            link.link = URL(string: "rwd://word/\(id)")
            link.foregroundColor = .init(.link)
            return link
        }
        return secondaryFragment(lemma)
    }

    private func secondaryFragment(_ text: String) -> AttributedString {
        var fragment = AttributedString(text)
        fragment.foregroundColor = .secondary
        return fragment
    }

    private func formsBlockView(_ block: WordFormsBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(block.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(block.rows.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Text(openRussianStressDisplay(row.value))
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    if index < block.rows.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }

    @ViewBuilder
    private func declensionTableView(_ table: WordFormsTable) -> some View {
        let columns = table.columns
        VStack(spacing: 0) {
            if columns.count >= 2 {
                HStack(spacing: 8) {
                    Text(columns[0])
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(columns.dropFirst(), id: \.self) { col in
                        Text(col)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 8)
                Divider()
            }

            ForEach(Array(table.rows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        Text(openRussianStressDisplay(cell))
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 6)
                if index < table.rows.count - 1 {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    /// OpenRussian CSV marks stress with `'` before the vowel; show as combining acute when possible.
    private func openRussianStressDisplay(_ text: String) -> String {
        var out = ""
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "'", i + 1 < chars.count {
                let next = chars[i + 1]
                if next.isLetter {
                    out.append(next)
                    out.append("\u{0301}")
                    i += 2
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}
