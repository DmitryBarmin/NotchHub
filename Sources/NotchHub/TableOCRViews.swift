import SwiftUI

struct TableOCRView: View {
    @ObservedObject var controller: TableOCRController
    @ObservedObject var store: HubStore
    @State private var copied: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Распознавание на Mac. Проверь ячейки перед копированием; пустые ячейки сохраняются.")
                .font(.caption).foregroundStyle(.secondary)
            if controller.busy {
                Spacer(); HStack { Spacer(); ProgressView("Распознаём строки и столбцы…"); Spacer() }; Spacer()
            } else if let table = controller.table {
                HStack {
                    Text("\(table.rowCount) строк × \(table.columnCount) столбцов").font(.caption).monospacedDigit()
                    Spacer()
                    Button("+ Строка") { resize(rows: table.rowCount + 1, columns: table.columnCount) }
                        .disabled(table.rowCount >= RecognizedTable.maxRows || (table.rowCount + 1) * table.columnCount > RecognizedTable.maxCells)
                    Button("+ Столбец") { resize(rows: table.rowCount, columns: table.columnCount + 1) }
                        .disabled(table.columnCount >= RecognizedTable.maxColumns || table.rowCount * (table.columnCount + 1) > RecognizedTable.maxCells)
                    Menu {
                        Button("Удалить последнюю строку") { resize(rows: table.rowCount - 1, columns: table.columnCount) }.disabled(table.rowCount <= 1)
                        Button("Удалить последний столбец") { resize(rows: table.rowCount, columns: table.columnCount - 1) }.disabled(table.columnCount <= 1)
                    } label: { Image(systemName: "ellipsis") }.help("Исправить размер таблицы")
                }
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 1, verticalSpacing: 1) {
                        GridRow {
                            Text("№").frame(width: 28)
                            ForEach(0..<table.columnCount, id: \.self) { column in Text("\(column + 1)").frame(width: 136) }
                        }.font(.caption).foregroundStyle(.secondary)
                        ForEach(0..<table.rowCount, id: \.self) { row in
                            GridRow {
                                Text("\(row + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 28)
                                ForEach(0..<table.columnCount, id: \.self) { column in
                                    TextField("", text: cell(row: row, column: column), axis: .vertical)
                                        .textFieldStyle(.plain).padding(6).frame(width: 136, alignment: .leading)
                                        .background(.quaternary.opacity(0.5))
                                        .accessibilityLabel("Строка \(row + 1), столбец \(column + 1)")
                                }
                            }
                        }
                    }.padding(.vertical, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    if let copied { Text(copied).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Копировать CSV") { copy(separator: ",", label: "CSV скопирован") }
                        .help("CSV с запятыми и экранированием кавычек")
                    Button("Копировать в таблицу") { copy(separator: "\t", label: "Таблица скопирована — вставь в Excel или Numbers") }
                        .buttonStyle(.borderedProminent).help("TSV: столбцы разделены табуляцией")
                }
            } else {
                ContentUnavailableView("Таблица не распознана", systemImage: "tablecells", description: Text(controller.message ?? "Выбери изображение таблицы или выдели её скриншотером."))
            }
        }.padding(14)
    }
    private func cell(row: Int, column: Int) -> Binding<String> {
        Binding(get: {
            guard let table = controller.table, table.cells.indices.contains(row), table.cells[row].indices.contains(column) else { return "" }
            return table.cells[row][column]
        }, set: { value in
            guard var table = controller.table, table.cells.indices.contains(row), table.cells[row].indices.contains(column), value.utf8.count <= 100_000 else { return }
            table.cells[row][column] = value
            guard let validated = try? RecognizedTable(cells: table.cells) else { copied = "Таблица превышает 30 МБ"; return }
            controller.table = validated; copied = nil
        })
    }
    private func resize(rows: Int, columns: Int) {
        guard let table = controller.table else { return }
        let cells = (0..<rows).map { row in (0..<columns).map { column in
            row < table.rowCount && column < table.columnCount ? table.cells[row][column] : ""
        } }
        if let updated = try? RecognizedTable(cells: cells) { controller.table = updated; copied = nil }
    }
    private func copy(separator: Character, label: String) {
        guard let table = controller.table else { return }
        let text = table.delimited(by: separator)
        guard store.addText(text), let clip = store.archive.clips.first else { copied = store.message ?? "Не удалось скопировать таблицу"; return }
        store.copy(clip); copied = label
    }
}
