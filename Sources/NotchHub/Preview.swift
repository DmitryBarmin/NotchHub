import AppKit
import SwiftUI
import AVKit
import Quartz
import UniformTypeIdentifiers

struct ClipPreviewView: View {
    let clip: Clip
    let url: URL?
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let text = clip.text {
                ScrollView {
                    Text(text).font(.system(size: 14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).padding(14)
                }
            } else if clip.kind == .image {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Text("Не удалось открыть изображение").foregroundStyle(.secondary) }
            } else if let url {
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true {
                    InlineVideoPreview(url: url)
                } else { FilePreview(url: url) }
            } else { Text("Файл недоступен").foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if clip.kind == .image, let url, let data = try? Data(contentsOf: url) { image = NSImage(data: data) }
        }
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
        view.player?.pause(); view.player = nil
    }
}

struct FilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false; view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
