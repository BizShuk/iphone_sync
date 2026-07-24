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
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title)
                                .font(Tokens.Typography.body)
                                .foregroundStyle(Tokens.Palette.wire)
                            Text("\(album.assetCount.formatted()) photos")
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(album.assetCount))
                            .font(Tokens.Typography.numericData)
                            .foregroundStyle(.secondary)
                        Image(
                            systemName: selectedIDs.contains(album.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.system(size: 18))
                        .foregroundStyle(
                            selectedIDs.contains(album.id)
                                ? Tokens.Palette.signal
                                : Tokens.Palette.frame
                        )
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(album.title), \(album.assetCount) photos"
                        + (selectedIDs.contains(album.id) ? ", selected" : "")
                )
            }
            .listStyle(.plain)
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
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
    }
}
