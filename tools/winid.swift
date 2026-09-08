import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let h = (w[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0
    if owner == "Attic", h > 300 {
        print(w[kCGWindowNumber as String] as? Int ?? 0); exit(0)
    }
}
print(0)
