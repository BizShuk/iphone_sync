import SwiftUI

struct AlbumPickerView: View {
    let albums: [PhotoAlbum]
    let select: (PhotoAlbum) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(albums) { album in
                Button {
                    select(album)
                    dismiss()
                } label: {
                    HStack {
                        Text(album.title)
                        Spacer()
                        Text(String(album.assetCount)).foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Choose Album")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
