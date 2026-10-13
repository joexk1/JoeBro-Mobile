import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let message = UILabel()
    private let groupID = (Bundle.main.object(forInfoDictionaryKey: "JoeBroAppGroup") as? String) ?? ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let logo = UIImageView(image: UIImage(systemName: "tray.and.arrow.down.fill"))
        logo.tintColor = .white
        logo.contentMode = .scaleAspectFit
        message.text = "Saving to JoeBro…"
        message.textColor = .white
        message.font = .systemFont(ofSize: 19, weight: .semibold)
        message.textAlignment = .center
        message.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [logo, message])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        logo.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -30),
            logo.widthAnchor.constraint(equalToConstant: 48), logo.heightAnchor.constraint(equalToConstant: 48)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        Task { await importItems() }
    }

    @objc private func close() { extensionContext?.completeRequest(returningItems: nil) }

    private func importItems() async {
        guard let defaults = UserDefaults(suiteName: groupID),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            message.text = "JoeBro sharing is unavailable on this device."
            return
        }
        let providers = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem }.flatMap { $0.attachments ?? [] } ?? []
        var text: String?
        var photo: Data?
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                text = [text, url.absoluteString].compactMap { $0 }.joined(separator: "\n")
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                let content = (value as? String) ?? (value as? URL)?.absoluteString ?? ""
                text = [text, content].compactMap { $0 }.joined(separator: "\n")
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let value = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) {
                if let image = value as? UIImage { photo = image.jpegData(compressionQuality: 0.76) }
                if let url = value as? URL, let data = try? Data(contentsOf: url) { photo = UIImage(data: data)?.jpegData(compressionQuality: 0.76) }
            }
        }
        guard text != nil || photo != nil else { message.text = "Nothing to import."; return }
        defaults.set(text ?? "", forKey: "pendingShareText")
        if let photo { try? photo.write(to: container.appendingPathComponent("pendingShare.jpg"), options: .atomic) }
        defaults.set(true, forKey: "pendingShare")
        message.text = "Saved to JoeBro. Open the app to review and send."
    }
}
