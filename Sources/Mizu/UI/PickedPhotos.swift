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

/// "+ photos" and the picked photos as small thumbnails, each with an ✕.
struct PhotoAttachments: View {
    @Binding var photos: [PickedPhoto]
    @Binding var loading: Int
    @State private var selection: [PhotosPickerItem] = []

    private let small = Font.system(.footnote, design: .monospaced)

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $selection, maxSelectionCount: PickedPhoto.maxCount, matching: .images) {
                    Text(photos.isEmpty ? "+ photos" : "+ / edit")
                        .font(small)
                        .padding(.horizontal, 10)
                        .frame(height: 64)
                        .overlay(Rectangle().stroke(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Attach photos")

                ForEach(photos) { photo in
                    Image(uiImage: photo.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipped()
                        .overlay(Rectangle().stroke(.secondary.opacity(0.4)))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                selection.removeAll { $0 == photo.id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                                    .frame(width: 18, height: 18)
                                    .background(Color.primary, in: Circle())
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Remove photo")
                        }
                }
                if loading > 0 {
                    ProgressView().frame(width: 64, height: 64)
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 8)
        }
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
#endif
