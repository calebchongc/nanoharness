import Darwin
import SafariServices
import SwiftUI

/// OpenAI's sign-in page in `SFSafariViewController` paired with a strictly
/// loopback (`127.0.0.1`) callback catcher. Unlike `WKWebView`,
/// `SFSafariViewController` runs on Safari's trusted engine so passkeys
/// (iCloud Keychain, Face ID, security keys) and Google sign-in work natively.
struct ChatGPTSignInBrowser: View {
    let signIn: AgentReauthentication.BrowserSignIn
    let onRedirect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var capture = CaptureController()

    var body: some View {
        Group {
            switch capture.state {
            case .listening:
                SafariSignInView(url: signIn.url) {
                    capture.stop()
                    dismiss()
                }
                .ignoresSafeArea()
            case .unavailable:
                NavigationStack {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Finish sign-in in Safari")
                            .font(Theme.sans(18, weight: .semibold))
                        Text("Harness couldn't listen on localhost port \(signIn.callbackPort) right now. Open the page in Safari to sign in with your passkey, then copy the final address back into the previous screen.")
                            .font(Theme.sans(14))
                            .foregroundStyle(Theme.textMuted)
                        Button("Open in Safari") {
                            openURL(signIn.url)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .padding(24)
                    .background(Theme.bg)
                    .navigationTitle("Sign in with ChatGPT")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { dismiss() }
                        }
                    }
                }
            }
        }
        .onAppear {
            capture.start(signIn: signIn) { redirect in
                onRedirect(redirect)
                dismiss()
            }
        }
        .onDisappear {
            capture.stop()
        }
    }
}

@MainActor
private final class CaptureController: ObservableObject {
    enum State { case listening, unavailable }
    @Published private(set) var state: State = .listening
    private var server: LoopbackCallbackServer?
    private var handed = false

    func start(signIn: AgentReauthentication.BrowserSignIn, onRedirect: @escaping @MainActor (String) -> Void) {
        guard server == nil else { return }
        guard signIn.callbackPort > 0, signIn.callbackPort <= Int(UInt16.max) else {
            state = .unavailable
            return
        }
        do {
            let listener = LoopbackCallbackServer()
            _ = try listener.start(port: UInt16(signIn.callbackPort), expectedPath: signIn.callbackPath) { [weak self] redirect in
                Task { @MainActor [weak self] in
                    guard let self, !self.handed else { return }
                    self.handed = true
                    self.stop()
                    onRedirect(redirect)
                }
            }
            server = listener
            state = .listening
        } catch {
            state = .unavailable
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }
}

private struct SafariSignInView: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = false
        let controller = SFSafariViewController(url: url, configuration: config)
        controller.dismissButtonStyle = .cancel
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}

/// Strictly loopback (`127.0.0.1`) one-shot HTTP callback catcher for relayed
/// OAuth sign-ins launched in `SFSafariViewController`.
final class LoopbackCallbackServer: @unchecked Sendable {
    enum Error: Swift.Error {
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
    }

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false
    private let queue = DispatchQueue(label: "harness.ios.loopback-callback", qos: .userInitiated)

    deinit {
        stop()
    }

    /// Parses `GET <expectedPath>?<query> HTTP/1.1` into `<expectedPath>?<query>`.
    static func parseCallbackTarget(requestLine: String, expectedPath: String) -> String? {
        let trimmed = requestLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = String(parts[1])
        guard let qIndex = target.firstIndex(of: "?") else { return nil }
        let path = String(target[..<qIndex])
        let queryStart = target.index(after: qIndex)
        guard path == expectedPath, queryStart < target.endIndex else { return nil }
        guard target.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else { return nil }
        return target
    }

    @discardableResult
    func start(port: UInt16, expectedPath: String, onCallback: @escaping @Sendable (String) -> Void) throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.socketFailed(errno) }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw Error.bindFailed(err)
        }
        guard Darwin.listen(fd, 8) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw Error.listenFailed(err)
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &len)
            }
        }
        let boundPort = UInt16(bigEndian: boundAddr.sin_port)

        lock.lock()
        self.listenFD = fd
        self.stopped = false
        lock.unlock()

        queue.async { [weak self] in
            self?.serve(fd: fd, boundPort: boundPort, expectedPath: expectedPath, onCallback: onCallback)
        }
        return boundPort
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serve(fd: Int32, boundPort: UInt16, expectedPath: String, onCallback: @escaping @Sendable (String) -> Void) {
        defer { stop() }
        while !isStopped() {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pfd, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            if (pfd.revents & Int16(POLLNVAL | POLLERR | POLLHUP)) != 0 { return }

            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            let target = handleClient(client, expectedPath: expectedPath)
            Darwin.close(client)
            if let target, !isStopped() {
                stop()
                onCallback("http://127.0.0.1:\(boundPort)\(target)")
                return
            }
        }
    }

    private func handleClient(_ client: Int32, expectedPath: String) -> String? {
        var yes: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        var total = 0
        var lineEnd: Int?
        while total < buffer.count {
            let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(client, base.advanced(by: total), raw.count - total)
            }
            if readCount <= 0 { break }
            total += readCount
            if let nl = buffer[0..<total].firstIndex(of: 0x0a) {
                lineEnd = nl
                break
            }
        }
        guard let end = lineEnd,
              let line = String(bytes: buffer[0..<end], encoding: .utf8),
              let target = Self.parseCallbackTarget(requestLine: line, expectedPath: expectedPath) else {
            Self.writeResponse(client, status: "404 Not Found", body: "Not found")
            return nil
        }
        let html = "<!doctype html><meta charset=utf-8><title>Harness</title>"
            + "<body style=\"font-family:-apple-system,system-ui,sans-serif;margin:4rem auto;max-width:28rem\">"
            + "<h2>Sign-in sent to Harness</h2><p>Returning to Harness…</p></body>"
        Self.writeResponse(client, status: "200 OK", body: html)
        return target
    }

    private static func writeResponse(_ client: Int32, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        response.withCString { ptr in
            var sent = 0
            let length = strlen(ptr)
            while sent < length {
                let n = Darwin.write(client, ptr.advanced(by: sent), length - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
