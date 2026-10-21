import AppKit
import Combine
import ImageIO
import Vision

struct RecognizedTable: Equatable {
    static let maxRows = 200
    static let maxColumns = 30
    static let maxCells = 4000
    var cells: [[String]]
    var rowCount: Int { cells.count }
    var columnCount: Int { cells.first?.count ?? 0 }
    init(cells: [[String]]) throws {
        let columns = cells.first?.count ?? 0
        guard !cells.isEmpty, columns > 0, cells.count <= Self.maxRows,
              columns <= Self.maxColumns, cells.count * columns <= Self.maxCells,
              cells.allSatisfy({ $0.count == columns }),
              cells.flatMap({ $0 }).reduce(0, { $0 + $1.utf8.count }) <= HubStore.maxBytes else {
            throw ClipActionFailure("Таблица слишком большая или строки имеют разное число ячеек (до 200 строк, 30 столбцов и 4000 ячеек)")
        }
        self.cells = cells
    }
    func delimited(by separator: Character) -> String {
        cells.map { row in
            row.map { cell in
                if cell.contains(separator) || cell.contains("\"") || cell.contains("\n") || cell.contains("\r") {
                    return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return cell
            }.joined(separator: String(separator))
        }.joined(separator: "\r\n")
    }
}

/// Vision rectangles use normalized coordinates with the origin at the bottom left.
struct TableTextRegion {
    var text: String
    var bounds: CGRect
}

enum TableGeometry {
    static func reconstruct(_ regions: [TableTextRegion]) throws -> RecognizedTable {
        let regions = regions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !regions.isEmpty else { throw ClipActionFailure("Текст не найден. Выдели таблицу крупнее или используй обычное распознавание текста.") }
        guard regions.count <= 8000, regions.allSatisfy({
            let r = $0.bounds
            return r.minX.isFinite && r.minY.isFinite && r.width.isFinite && r.height.isFinite && r.width > 0 && r.height > 0 &&
                r.minX >= 0 && r.minY >= 0 && r.maxX <= 1.001 && r.maxY <= 1.001
        }) else { throw ClipActionFailure("Слишком много текста или неверная геометрия изображения") }
        let heights = regions.map(\.bounds.height).sorted()
        let typicalHeight = heights[heights.count / 2]
        let rowTolerance = max(0.002, typicalHeight * 0.55)
        let characterWidths = regions.map { $0.bounds.width / CGFloat(max(1, $0.text.count)) }.sorted()
        let columnTolerance = max(0.003, min(0.025, characterWidths[characterWidths.count / 2] * 2))
        var rows: [[TableTextRegion]] = []
        for region in regions.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            if let index = rows.lastIndex(where: { row in
                abs(row.map(\.bounds.midY).reduce(0, +) / CGFloat(row.count) - region.bounds.midY) <= rowTolerance
            }) { rows[index].append(region) }
            else { rows.append([region]) }
        }
        guard rows.count >= 2, rows.filter({ $0.count >= 2 }).count >= 2 else {
            throw ClipActionFailure("Не удалось уверенно найти строки и столбцы. Выдели только таблицу; для обычного текста используй OCR.")
        }
        guard rows.count <= RecognizedTable.maxRows else { throw ClipActionFailure("Выдели не больше 200 строк таблицы") }
        rows = rows.map { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
        struct Column { var left: CGFloat; var right: CGFloat; var members: [(Int, TableTextRegion)] }
        var columns: [Column] = []
        // The fullest row gives stable anchors; subsequent rows can add missing columns.
        let orderedRows = rows.indices.sorted { rows[$0].count > rows[$1].count }
        for rowIndex in orderedRows {
            for region in rows[rowIndex] {
                let candidates = columns.indices.filter { index in
                    let column = columns[index]
                    return abs(column.left - region.bounds.minX) <= columnTolerance || abs(column.right - region.bounds.maxX) <= columnTolerance
                }
                guard candidates.count <= 1 else { throw ClipActionFailure("Столбцы неоднозначны. Выдели таблицу без окружающего текста или исправь её через обычный OCR.") }
                if let index = candidates.first {
                    guard !columns[index].members.contains(where: { $0.0 == rowIndex }) else {
                        throw ClipActionFailure("Ячейки перекрываются. Попробуй более крупный и ровный снимок таблицы.")
                    }
                    let count = CGFloat(columns[index].members.count)
                    columns[index].left = (columns[index].left * count + region.bounds.minX) / (count + 1)
                    columns[index].right = (columns[index].right * count + region.bounds.maxX) / (count + 1)
                    columns[index].members.append((rowIndex, region))
                } else { columns.append(Column(left: region.bounds.minX, right: region.bounds.maxX, members: [(rowIndex, region)])) }
            }
        }
        columns.sort { $0.left < $1.left }
        // Repeated body cells establish the columns. A centered header must not
        // create a phantom column merely because its text has different edges.
        let singletons = columns.filter { $0.members.count == 1 }
        columns = columns.filter { $0.members.count >= 2 }
        guard columns.count >= 2 else {
            throw ClipActionFailure("Недостаточно повторяющихся столбцов. Выдели таблицу с несколькими строками данных.")
        }
        for singleton in singletons {
            let center = (singleton.left + singleton.right) / 2
            let candidates = columns.indices.filter { index in
                let anchor = (columns[index].left + columns[index].right) / 2
                let leftDistance = index > 0 ? anchor - (columns[index - 1].left + columns[index - 1].right) / 2 : CGFloat.infinity
                let rightDistance = index + 1 < columns.count ? (columns[index + 1].left + columns[index + 1].right) / 2 - anchor : CGFloat.infinity
                let spacing = min(leftDistance, rightDistance)
                return abs(center - anchor) < spacing * 0.45
            }
            guard candidates.count == 1, let index = candidates.first,
                  !columns[index].members.contains(where: { $0.0 == singleton.members[0].0 }) else {
                throw ClipActionFailure("Заголовки или столбцы неоднозначны. Выдели только таблицу без окружающего текста.")
            }
            columns[index].members.append(contentsOf: singleton.members)
        }
        guard columns.count >= 2, columns.count <= RecognizedTable.maxColumns,
              rows.count * columns.count <= RecognizedTable.maxCells,
              columns.filter({ $0.members.count >= 2 }).count >= 2 else {
            throw ClipActionFailure("Не удалось уверенно определить столбцы (до 30 столбцов и 4000 ячеек). Выдели меньшую область.")
        }
        var cells = Array(repeating: Array(repeating: "", count: columns.count), count: rows.count)
        for (column, group) in columns.enumerated() {
            for (row, region) in group.members { cells[row][column] = region.text }
        }
        return try RecognizedTable(cells: cells)
    }
}

final class TableOCRController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published var table: RecognizedTable?
    private let queue = OperationQueue()
    private var generation = UUID()
    private let recognizer: (CGImage) throws -> [TableTextRegion]
    init(recognizer: ((CGImage) throws -> [TableTextRegion])? = nil) {
        self.recognizer = recognizer ?? Self.regions
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
    }
    static func regions(in image: CGImage) throws -> [TableTextRegion] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        let languages = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["ru-RU", "en-US"].filter { languages.contains($0) }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard (request.results?.count ?? 0) <= 8000 else { throw ClipActionFailure("Слишком много текста — выдели меньшую область") }
        return try (request.results ?? []).flatMap { observation -> [TableTextRegion] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            // Keep natural spaces inside labels. Only explicit multi-space/tab gaps split merged rows.
            let string = candidate.string
            let expression = try NSRegularExpression(pattern: "[^\\t ](?:.*?[^\\t ])?(?= {2,}|\\t+|$)")
            let ranges = expression.matches(in: string, range: NSRange(string.startIndex..., in: string))
            if ranges.count > 1 {
                return ranges.compactMap { match in
                    guard let range = Range(match.range, in: string), let box = try? candidate.boundingBox(for: range) else { return nil }
                    return TableTextRegion(text: String(string[range]), bounds: box.boundingBox)
                }
            }
            return [TableTextRegion(text: string, bounds: observation.boundingBox)]
        }
    }
    func recognize(url: URL, completion: ((Result<RecognizedTable, Error>) -> Void)? = nil) {
        run(load: {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= HubStore.maxBytes,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 3000, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw ClipActionFailure("Не удалось открыть изображение (до 30 МБ)")
            }
            return image
        }, completion: completion)
    }
    func recognize(image: CGImage, completion: ((Result<RecognizedTable, Error>) -> Void)? = nil) {
        run(load: {
            guard image.width <= 16000, image.height <= 16000, image.width * image.height <= 40_000_000 else {
                throw ClipActionFailure("Слишком большая область — выдели таблицу отдельно")
            }
            return image
        }, completion: completion)
    }
    private func run(load: @escaping () throws -> CGImage, completion: ((Result<RecognizedTable, Error>) -> Void)?) {
        cancel(); let token = UUID(); generation = token; busy = true; message = nil; table = nil
        let recognizer = self.recognizer
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = Result<RecognizedTable, Error> {
                let image = try load()
                guard operation?.isCancelled == false else { throw CancellationError() }
                let regions = try recognizer(image)
                guard operation?.isCancelled == false else { throw CancellationError() }
                return try TableGeometry.reconstruct(regions)
            }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.busy = false
                switch result {
                case .success(let table): self.table = table
                case .failure(let error): self.message = error.localizedDescription
                }
                completion?(result)
            }
        }
        queue.addOperation(operation)
    }
    func cancel() { generation = UUID(); queue.cancelAllOperations(); busy = false; table = nil; message = nil }
    deinit { queue.cancelAllOperations() }
}
