#if canImport(UIKit)
import PhotosUI
import SwiftUI
import UIKit

/// A photo from the camera roll, attached to a report (e.g. a mockup or a screenshot from another app).
struct PickedPhoto: Identifiable, Equatable {
    let id: PhotosPickerItem
    let thumbnail: UIImage
    let jpeg: Data

    static let maxCount = 5
    static let maxSide: CGFloat = 2000

    /// Shrinks to at most 2000px on the long side and re-encodes as JPEG (HEIC, PNG and the rest all come out the same).
    static func prepare(_ data: Data, id: PhotosPickerItem) -> PickedPhoto? {
        guard let image = UIImage(data: data) else { return nil }
        guard let jpeg = resized(image, maxSide: maxSide).jpegData(compressionQuality: 0.85) else { return nil }
        return PickedPhoto(id: id, thumbnail: resized(image, maxSide: 180), jpeg: jpeg)
    }

    static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }

    static func == (a: PickedPhoto, b: PickedPhoto) -> Bool { a.id == b.id }

    /// Outbox parts for the photos, named photo-1.jpg, photo-2.jpg, …
    static func parts(_ photos: [Data]) -> [OutboxPart] {
        photos.enumerated().map { i, data in
            MizuAttachment(name: "photo-\(i + 1).jpg", data: data, contentType: "image/jpeg").outboxPart
        }
    }
}

/// The picked photos as tiles, each with an ✕, then a "+" tile that opens the system photo picker.
/// Sits in the report sheet's attachment row, after the screenshot and voice note.
struct PhotoAttachments: View {
    @Binding var photos: [PickedPhoto]
    @Binding var loading: Int
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        ForEach(photos) { photo in
            Image(uiImage: photo.thumbnail)
                .resizable()
                .scaledToFill()
                .mizuTile()
                .overlay(alignment: .topTrailing) {
                    TileBadge(symbol: "xmark") { selection.removeAll { $0 == photo.id } }
                        .accessibilityLabel("Remove photo")
                }
        }
        ForEach(0..<loading, id: \.self) { _ in
            ProgressView().mizuTile(filled: true)
        }
        // Always there (the picker also edits the selection); just faint once there are five.
        PhotosPicker(selection: $selection, maxSelectionCount: PickedPhoto.maxCount, matching: .images) {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.secondary)
                .mizuTile(width: MizuTile.addWidth, filled: true)
                .opacity(photos.count + loading < PickedPhoto.maxCount ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photos.isEmpty ? "Attach photos" : "Change attached photos")
        .onChange(of: selection) { items in
            photos.removeAll { !items.contains($0.id) }
            let new = items.filter { item in !photos.contains { $0.id == item } }
            for item in new { load(item) }
        }
    }

    private func load(_ item: PhotosPickerItem) {
        loading += 1
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            let photo = await Task.detached(priority: .userInitiated) { data.flatMap { PickedPhoto.prepare($0, id: item) } }.value
            await MainActor.run {
                loading -= 1
                // Still picked, and keep the picker's order.
                guard let photo, selection.contains(item) else { return }
                photos.append(photo)
                photos.sort { a, b in (selection.firstIndex(of: a.id) ?? 0) < (selection.firstIndex(of: b.id) ?? 0) }
            }
        }
    }
}

/// The report sheet's attachment tiles: all the same height, 3:4 unless they have a shape of their own (the screenshot).
enum MizuTile {
    static let height: CGFloat = 88
    static let width: CGFloat = 66
    /// "+" is an offer, not content: narrower than what it adds.
    static let addWidth: CGFloat = 44
}

extension View {
    /// Images get a hairline so a white screen doesn't melt into the sheet; `filled` tiles (voice, "+") are a soft
    /// wash instead, no edge.
    func mizuTile(width: CGFloat = MizuTile.width, filled: Bool = false) -> some View {
        frame(width: width, height: MizuTile.height)
            .background(Color.primary.opacity(filled ? 0.05 : 0))
            .contentShape(Rectangle())
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(filled ? 0 : 0.12), lineWidth: 0.5)
            )
    }
}

/// The small round button on a tile's corner: ✕ to take it out, + to put it back.
struct TileBadge: View {
    let symbol: String
    let action: () -> Void

    /// How far the badge hangs past the tile's corner; the row leaves this much room.
    static let overhang: CGFloat = 6

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.primary))
                .frame(width: 32, height: 32) // a fingertip, not a pinhead
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Centre the 16pt circle so its edge hangs `overhang` past the tile's corner.
        .offset(x: 16 - 8 + Self.overhang, y: -(16 - 8 + Self.overhang))
    }
}
#endif
