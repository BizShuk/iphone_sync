import SwiftUI

struct AlbumPickerView: View {
    let albums: [PhotoAlbum]
    let save: ([PhotoAlbum]) -> Void
    @State private var selectedIDs: Set<String>
    @Environment(\.dismiss) private var dismiss

    init(
        albums: [PhotoAlbum],
        selectedAlbums: [PhotoAlbum],
        save: @escaping ([PhotoAlbum]) -> Void
    ) {
        self.albums = albums
        self.save = save
        _selectedIDs = State(initialValue: Set(selectedAlbums.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List(albums) { album in
                Button {
                    if selectedIDs.contains(album.id) {
                        selectedIDs.remove(album.id)
                    } else {
                        selectedIDs.insert(album.id)
                    }
                } label: {
                    HStack {
                        Text(album.title)
                        Spacer()
                        Text(String(album.assetCount)).foregroundStyle(.secondary)
                        Image(
                            systemName: selectedIDs.contains(album.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .foregroundStyle(
                            selectedIDs.contains(album.id) ? Color.accentColor : .secondary
                        )
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Choose Albums")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(albums.filter { selectedIDs.contains($0.id) })
                        dismiss()
                    }
                }
            }
        }
    }
}
