import Foundation

struct SharedCapture {
    let text: String
    let imageData: Data?
}

enum ShareInbox {
    static let groupID = (Bundle.main.object(forInfoDictionaryKey: "JoeBroAppGroup") as? String) ?? ""
    static var hasPending: Bool { UserDefaults(suiteName: groupID)?.bool(forKey: "pendingShare") == true }
    static func read() -> SharedCapture? {
        guard let defaults = UserDefaults(suiteName: groupID), defaults.bool(forKey: "pendingShare") else { return nil }
        let value = defaults.string(forKey: "pendingShareText") ?? ""
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("pendingShare.jpg")
        let photo = url.flatMap { try? Data(contentsOf: $0) }
        return SharedCapture(text: value, imageData: photo)
    }
    static func clear() {
        let defaults = UserDefaults(suiteName: groupID)
        defaults?.removeObject(forKey: "pendingShare")
        defaults?.removeObject(forKey: "pendingShareText")
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("pendingShare.jpg") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
