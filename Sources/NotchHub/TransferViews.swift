import AppKit
import ImageIO
import SwiftUI

struct TransferSettingsView: View {
    @ObservedObject var settings: TransferSettings
    @State private var endpoint = ""
    @State private var key = ""
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsHeading(title: "Передача между Mac", icon: "arrow.left.arrow.right")
                Text("Элементы шифруются на Mac. Сервер хранит передачу один час; ключ расшифровки находится только в ссылке.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("HTTPS-адрес сервера", text: $endpoint).textFieldStyle(.roundedBorder)
                SecureField("Ключ отправки", text: $key).textFieldStyle(.roundedBorder)
                Text("Ключ отправки сохраняется в Связке ключей. Для получения по ссылке он не нужен.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let message = settings.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Сохранить") { _ = settings.save(endpoint: endpoint, key: key) }.buttonStyle(.borderedProminent)
                }
            }
        }.onAppear { endpoint = settings.endpointURL?.absoluteString ?? ""; key = settings.uploadKey }
    }
}

struct TransferWindowView: View {
    @ObservedObject var service: ClipboardTransfer
    @ObservedObject var store: HubStore
    let accept: ([TransferItem]) -> Void
    @State private var invitation = ""
    @State private var invitationError: String?
    @State private var qrImage: NSImage?
    @State private var qrError: String?
    private func showQR(_ text: String) {
        do { qrImage = try QuickShareController.qrImage(text: text); qrError = nil }
        catch { qrError = error.localizedDescription }
    }
    private func selected(_ clip: Clip) -> Binding<Bool> {
        Binding(get: { service.selectedClips.contains { $0.id == clip.id } }, set: { enabled in
            if enabled {
                if service.selectedClips.count < TransferCodec.itemLimit { service.selectedClips.append(clip) }
            } else { service.selectedClips.removeAll { $0.id == clip.id } }
        })
    }
    var body: some View {
        Group {
        if let qrImage {
            VStack(spacing: 10) {
                Button("Назад к передаче") { self.qrImage = nil }
                Image(nsImage: qrImage).interpolation(.none).resizable().scaledToFit().padding(16).background(.white)
                Text("Создан на Mac · без отправки в сеть").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        } else {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("Передача", systemImage: "arrow.left.arrow.right").font(.title2.weight(.semibold))
                    Spacer()
                    if service.busy { ProgressView().controlSize(.small) }
                }
                if !store.preferences.isEnabled(.sharing) {
                    Text("Передача выключена в настройках возможностей.").foregroundStyle(.secondary)
                } else {
                    if !service.incoming.isEmpty { incomingCard }
                    receiveCard
                    sendCard
                }
                if let message = service.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if let message = qrError { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(24)
        }
        }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var incomingCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                SettingsHeading(title: "Получено: \(service.incoming.count) отдельных элементов", icon: "tray.and.arrow.down")
                ForEach(service.incoming) { item in
                    HStack(spacing: 12) {
                        TransferThumbnail(item: item)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).lineLimit(2)
                            if let text = item.text { Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            else if let data = item.data { Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Text("Каждое изображение появится отдельной записью в истории. До подтверждения ничего не сохраняется.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Отклонить") { service.dismissIncoming() }
                    Spacer()
                    Button("Добавить в историю") { accept(service.incoming) }.buttonStyle(.borderedProminent)
                }.disabled(service.busy)
            }
        }
    }
    private var receiveCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                SettingsHeading(title: "Получить по ссылке", icon: "link")
                HStack {
                    SecureField("Вставь ссылку NotchHub", text: $invitation).textFieldStyle(.roundedBorder)
                    Button("Получить") {
                        if let url = URL(string: invitation.trimmingCharacters(in: .whitespacesAndNewlines), encodingInvalidCharacters: false) {
                            service.receive(url: url)
                            invitation = ""; invitationError = nil
                        } else { invitationError = "Вставь полную ссылку-приглашение NotchHub" }
                    }.disabled(service.busy || invitation.isEmpty || !service.incoming.isEmpty)
                }
                if let invitationError { Text(invitationError).font(.caption).foregroundStyle(.red) }
                Text("Или открой ссылку, полученную через AirDrop. Расшифровка происходит только на этом Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var sendCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                SettingsHeading(title: "Отправить выбранное", icon: "tray.and.arrow.up")
                Text("До 20 элементов, 30 МБ на элемент и 60 МБ на передачу. AirDrop отправляет одну ссылку для импорта в NotchHub.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.archive.clips.isEmpty { Text("История пока пуста").foregroundStyle(.secondary) }
                ForEach(store.archive.clips) { clip in
                    Toggle(isOn: selected(clip)) {
                        HStack {
                            if clip.kind == .image, let url = store.assetURL(clip) {
                                AssetImageView(url: url, maxPixelSize: 120, fill: false)
                                    .frame(width: 54, height: 34).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            } else { Image(systemName: clip.kind == .text ? "text.alignleft" : "doc").frame(width: 24) }
                            Text(clip.title).lineLimit(1)
                        }.font(.system(size: 12))
                    }.toggleStyle(.checkbox).disabled(service.busy || (!service.selectedClips.contains { $0.id == clip.id } && service.selectedClips.count >= TransferCodec.itemLimit))
                }
                HStack {
                    Text("Выбрано: \(service.selectedClips.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Отправить выбранное") { service.send(clips: service.selectedClips, store: store) }
                        .buttonStyle(.borderedProminent).disabled(service.busy || service.selectedClips.isEmpty)
                }
                if let link = service.shareURL {
                    Divider()
                    Text("Передача готова · 1 час").font(.system(size: 12, weight: .medium))
                    HStack {
                        Button("Скопировать ссылку") { service.copyLink() }
                        Button("AirDrop…") { service.airDrop() }
                        Button("QR ссылки") { showQR(link.absoluteString) }
                    }
                }
                if service.selectedClips.count == 1, let text = service.selectedClips.first?.text {
                    Divider()
                    HStack {
                        Button("QR текста") { showQR(text) }.disabled(text.utf8.count > 2048 || text.isEmpty)
                        TransferTextSharingButton(text: text)
                    }
                    Text("Текст и обычные ссылки можно передать через QR или системное меню без загрузки на сервер.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TransferThumbnail: View {
    let item: TransferItem
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: item.kind == .image ? "photo" : (item.kind == .text ? "text.alignleft" : "doc")).font(.title2).foregroundStyle(.secondary) }
        }.frame(width: 90, height: 64).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .task(id: item.id) {
                guard item.kind == .image, let data = item.data else { return }
                let thumbnail = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }.value
                if let thumbnail { image = NSImage(cgImage: thumbnail, size: .zero) }
            }
    }
}

private struct TransferTextSharingButton: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Системное меню…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.text = text }
    func makeCoordinator() -> Coordinator { Coordinator(text: text) }
    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var text: String
        private var picker: NSSharingServicePicker?
        init(text: String) { self.text = text }
        @objc func share(_ button: NSButton) {
            let picker = NSSharingServicePicker(items: [text]); self.picker = picker; picker.delegate = self
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) { picker = nil }
    }
}
