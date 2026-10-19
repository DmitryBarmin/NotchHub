import Foundation
import SwiftUI

enum UUIDBatch {
    static let limit = 100
    static func boundedCount(_ count: Int) -> Int { max(1, min(limit, count)) }
    static func generate(count: Int) -> [String] {
        (0..<boundedCount(count)).map { _ in UUID().uuidString.lowercased() }
    }
    static func text(_ values: [String]) -> String { values.joined(separator: "\n") }
}

struct UUIDGeneratorView: View {
    let copy: (String) -> Void
    @State private var count = 1
    @State private var values = UUIDBatch.generate(count: 1)
    @State private var message: String?
    private func generate() {
        count = UUIDBatch.boundedCount(count)
        values = UUIDBatch.generate(count: count)
        message = nil
    }
    private func copyText(_ text: String, message: String) {
        copy(text)
        self.message = message
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Количество").font(.caption)
                TextField("1–100", value: $count, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 56)
                    .onSubmit { generate() }
                    .help("Количество UUID: от 1 до 100").accessibilityLabel("Количество UUID")
                Stepper("Количество UUID", value: $count, in: 1...UUIDBatch.limit).labelsHidden()
                Spacer()
                Button(action: generate) { Image(systemName: "arrow.clockwise").frame(width: 28, height: 26) }
                    .help("Сгенерировать UUID").accessibilityLabel("Сгенерировать UUID")
                Button { copyText(UUIDBatch.text(values), message: "Скопировано UUID: \(values.count)") } label: {
                    Image(systemName: "doc.on.doc").frame(width: 28, height: 26)
                }.help("Копировать все UUID").accessibilityLabel("Копировать все UUID")
            }
            Text("UUID v4 · создано: \(values.count) · только на Mac").font(.caption).foregroundStyle(.secondary)
            List(values.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    if values.count > 1 { Text("\(index + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing) }
                    Text(values[index]).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Button { copyText(values[index], message: "UUID скопирован") } label: {
                        Image(systemName: "doc.on.doc").frame(width: 24, height: 24)
                    }.buttonStyle(.borderless).help("Копировать UUID №\(index + 1)").accessibilityLabel("Копировать UUID №\(index + 1)")
                }.padding(.vertical, 3)
            }.listStyle(.plain)
            Text(message ?? "Выдели UUID или скопируй кнопкой. При создании буфер не меняется.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }
}
