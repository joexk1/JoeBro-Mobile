import SwiftUI
import AVFoundation
import Observation

/// Receives `joebro://pair` links from anywhere in the app.
@Observable @MainActor
final class PairingInbox {
    static let shared = PairingInbox()
    var incoming: PairingPayload?
}

/// Shown until a backend is paired, and again from Settings > Pair again.
struct OnboardingView: View {
    let theme: JoeBroTheme
    var allowCancel = false
    var onPaired: () -> Void
    var onCancel: () -> Void = {}

    @State private var page = 0
    @State private var scanning = false
    @State private var showManual = false
    @State private var link = ""
    @State private var url = ""
    @State private var token = ""
    @State private var busy = false
    @State private var message: String?
    @State private var paired: String?
    @State private var inbox = PairingInbox.shared

    var body: some View {
        ZStack {
            WallpaperBackground(theme: theme)
            VStack(spacing: 0) {
                if allowCancel {
                    HStack { Spacer(); Button("Cancel", action: onCancel).padding() }
                }
                TabView(selection: $page) {
                    infoPage("JoeBro on your phone", "JoeBro on your phone talks to the JoeBro backend you run. Nothing goes through anyone else's server.", "iphone.gen3").tag(0)
                    infoPage("Turn on mobile access", "In JoeBro on your computer, open Settings, then Mobile, and turn on \"Let my phone connect\". On the same Wi-Fi it just works. Away from home, install Tailscale on both devices.", "desktopcomputer").tag(1)
                    pairPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
        }
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                scanning = false
                if let payload = PairingPayload.parse(text: code) { Task { await pair(payload) } }
                else { message = "That QR code is not a JoeBro pairing code." }
            }
            .ignoresSafeArea()
        }
        .task { consumeIncoming() }
        .onChange(of: inbox.incoming) { _, _ in consumeIncoming() }
    }

    private func consumeIncoming() {
        guard let payload = inbox.incoming else { return }
        inbox.incoming = nil
        page = 2
        Task { await pair(payload) }
    }

    private func infoPage(_ title: String, _ text: String, _ symbol: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 64)).foregroundStyle(Color.accentTint)
            Text(title).font(.title.bold()).multilineTextAlignment(.center)
            Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Next") { withAnimation { page += 1 } }.buttonStyle(.borderedProminent).controlSize(.large)
            Spacer(); Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var pairPage: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("JoeBroLogo").resizable().scaledToFit().frame(width: 72, height: 72).padding(.top, 40)
                Text("Pair this phone").font(.title.bold())
                if let paired {
                    Label("Paired with \(paired)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button { requestCamera() } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)

                Button(showManual ? "Hide details" : "Paste link or enter details") {
                    withAnimation { showManual.toggle() }
                }.font(.footnote)

                if showManual {
                    VStack(spacing: 12) {
                        TextField("Pairing link (joebro://pair?...)", text: $link)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: link) { _, v in
                                if let p = PairingPayload.parse(text: v) { url = p.url; token = p.token }
                            }
                        TextField("Backend URL (http://host:8771)", text: $url)
                            .keyboardType(.URL).textFieldStyle(.roundedBorder)
                        SecureField("Token", text: $token).textFieldStyle(.roundedBorder)
                        Button("Pair") { Task { await pair(PairingPayload(url: url, token: token, name: "")) } }
                            .buttonStyle(.bordered).disabled(url.isEmpty || busy)
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if busy { ProgressView() }
                if let message { Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
            }
            .padding(.horizontal, 32).padding(.bottom, 60)
        }
    }

    private func requestCamera() {
        message = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: scanning = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { if ok { scanning = true } else { message = "Camera access is off. Use \"Paste link or enter details\" instead." } }
            }
        default: message = "Camera access is off in iPhone Settings. Use \"Paste link or enter details\" instead."
        }
    }

    private func pair(_ payload: PairingPayload) async {
        busy = true; message = nil
        defer { busy = false }
        do {
            let result = try await Pairing.verify(payload)
            ServerConfig.save(url: result.url, token: result.token, name: result.name, features: result.features)
            paired = result.name.isEmpty ? "your backend" : result.name
            try? await Task.sleep(for: .milliseconds(600))
            onPaired()
        } catch { message = error.localizedDescription }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController(); vc.onCode = onCode; return vc
    }
    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
            let label = UILabel()
            label.text = "Scan the QR code shown in JoeBro on your computer"
            label.textColor = .white; label.textAlignment = .center; label.numberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
            ])
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            onCode?(code)
        }
    }
}
