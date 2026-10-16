import Foundation

struct TextTemplate: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var text: String
}
struct Workspace: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var note: String = ""
}
struct Archive: Codable {
    var clips: [Clip] = []
    var shelf: [Clip] = []
    var note: String = ""
    var favorites: [Clip] = []
    var templates: [TextTemplate] = []
    var workspaces: [Workspace] = []
    var activeWorkspaceID: UUID?
    init() {}
    private enum CodingKeys: String, CodingKey { case clips, shelf, note, favorites, templates, workspaces, activeWorkspaceID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clips = try values.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        shelf = try values.decodeIfPresent([Clip].self, forKey: .shelf) ?? []
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        favorites = try values.decodeIfPresent([Clip].self, forKey: .favorites) ?? []
        templates = try values.decodeIfPresent([TextTemplate].self, forKey: .templates) ?? []
        workspaces = try values.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        activeWorkspaceID = try values.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID)
    }
}
