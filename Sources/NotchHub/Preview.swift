import AppKit
import SwiftUI
import AVKit
import Quartz
import UniformTypeIdentifiers
import ImageIO

struct ClipPreviewView: View {
    let clip: Clip
    let url: URL?
    var backgroundOpacity: Double = 1
    var body: some View {
        Group {
            if let text = clip.text {
                ScrollView {
                    Text(text).font(.system(size: 14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).padding(14)
                }
            } else if clip.kind == .image {
                if let url {
                    AssetImageView(url: url, maxPixelSize: 1400, fill: false).padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Text("Не удалось открыть изображение").foregroundStyle(.secondary) }
            } else if let url {
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true {
                    InlineVideoPreview(url: url)
                } else { FilePreview(url: url) }
            } else { Text("Файл недоступен").foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.18 * backgroundOpacity), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))

    }
}

struct InlineVideoPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause(); view.player?.replaceCurrentItem(with: nil); view.player = nil
    }
}

struct FilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false; view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

// Decode only display-sized pixels, never a full-size raster in a SwiftUI body.
// NSCache is thread-safe; job/request state is protected by locks.
final class AssetImageCache: @unchecked Sendable {
    static let shared = AssetImageCache()
    private let images = NSCache<NSString, NSImage>()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var jobs: [String: DecodeJob] = [:]
    private let decode: (URL, Int) -> NSImage?
    init(decoder: ((URL, Int) -> NSImage?)? = nil) {
        images.totalCostLimit = 12 * 1024 * 1024; images.countLimit = 48
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        decode = decoder ?? Self.decodeImage
    }
    private final class DecodeRequest: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var cancelled = false
        private var continuation: CheckedContinuation<NSImage?, Never>?
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func install(_ continuation: CheckedContinuation<NSImage?, Never>) {
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(returning: nil) }
            else { self.continuation = continuation; lock.unlock() }
        }
        func finish(_ image: NSImage?) {
            lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
            continuation?.resume(returning: image)
        }
        func cancel() { lock.lock(); cancelled = true; lock.unlock(); finish(nil) }
    }
    // Every field is accessed while holding the owning cache lock.
    private final class DecodeJob: @unchecked Sendable {
        var requests: [UUID: DecodeRequest] = [:]
        var started = false
        var operation: BlockOperation?
    }
    var pendingDecodeRequests: Int { lock.lock(); defer { lock.unlock() }; return jobs.values.reduce(0) { $0 + $1.requests.count } }
    func load(url: URL, maxPixelSize: Int) async -> NSImage? {
        let key = "\(url.path):\(maxPixelSize)", request = DecodeRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.install(continuation)
                lock.lock()
                if request.isCancelled { lock.unlock(); return }
                if let cached = images.object(forKey: key as NSString) { lock.unlock(); request.finish(cached); return }
                if let job = jobs[key] { job.requests[request.id] = request; lock.unlock(); return }
                let job = DecodeJob(); job.requests[request.id] = request
                let operation = BlockOperation { [weak self, weak job] in
                    guard let self, let job else { return }
                    self.lock.lock()
                    guard self.jobs[key] === job, !job.requests.isEmpty else { self.lock.unlock(); return }
                    job.started = true
                    self.lock.unlock()
                    let image = self.image(url: url, maxPixelSize: maxPixelSize)
                    self.lock.lock()
                    let requests = Array(job.requests.values); job.requests.removeAll()
                    if self.jobs[key] === job { self.jobs.removeValue(forKey: key) }
                    self.lock.unlock()
                    requests.forEach { $0.finish(image) }
                }
                job.operation = operation; jobs[key] = job
                queue.addOperation(operation); lock.unlock()
            }
        } onCancel: {
            request.cancel()
            self.lock.lock()
            if let job = self.jobs[key] {
                job.requests.removeValue(forKey: request.id)
                if job.requests.isEmpty && !job.started { job.operation?.cancel(); self.jobs.removeValue(forKey: key) }
            }
            self.lock.unlock()
        }
    }
    func image(url: URL, maxPixelSize: Int) -> NSImage? {
        let key = "\(url.path):\(maxPixelSize)" as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let image = decode(url, maxPixelSize) else { return nil }
        let cost = Int(image.size.width * image.size.height) * 4
        images.setObject(image, forKey: key, cost: cost)
        return image
    }
    private static func decodeImage(url: URL, maxPixelSize: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }
}

struct AssetImageView: View {
    let url: URL
    let maxPixelSize: Int
    let fill: Bool
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                if fill { Image(nsImage: image).resizable().scaledToFill() }
                else { Image(nsImage: image).resizable().scaledToFit() }
            } else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .task(id: url.path) {
            let loaded = await AssetImageCache.shared.load(url: url, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
