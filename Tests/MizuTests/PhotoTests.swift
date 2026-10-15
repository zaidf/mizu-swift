#if canImport(UIKit)
import UIKit
import XCTest
@testable import Mizu

final class PhotoTests: XCTestCase {
    func testBigPhotosAreShrunkAndNamedInOrder() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let small = PickedPhoto.resized(big, maxSide: PickedPhoto.maxSide)
        XCTAssertEqual(small.size.width * small.scale, 2000)
        XCTAssertEqual(small.size.height * small.scale, 1500)

        let parts = PickedPhoto.parts([Data([1]), Data([2])])
        XCTAssertEqual(parts.map(\.name), ["attachment:photo-1.jpg", "attachment:photo-2.jpg"])
        XCTAssertEqual(parts.map(\.contentType), ["image/jpeg", "image/jpeg"])
    }

    func testSmallPhotosKeepTheirSize() {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { _ in }
        let out = PickedPhoto.resized(img, maxSide: PickedPhoto.maxSide)
        XCTAssertEqual(out.size.width * out.scale, 300)
    }
}
#endif
