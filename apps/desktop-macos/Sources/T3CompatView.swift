import AppKit
import SwiftUI
import WebKit

enum T3NavigationDisposition: Equatable {
    case embedded
    case external
    case blocked
}

enum T3NavigationPolicy {
    static func disposition(for url: URL, origin: URL) -> T3NavigationDisposition {
        if url.absoluteString == "about:blank" { return .embedded }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return .blocked
        }
        if scheme == origin.scheme?.lowercased(),
           url.host?.lowercased() == origin.host?.lowercased(),
           url.port == origin.port {
            return .embedded
        }
        return .external
    }
}

enum T3CookiePolicy {
    static func cookies(for origin: URL, from cookies: [HTTPCookie]) -> [HTTPCookie] {
        guard let host = origin.host?.lowercased() else { return [] }
        return cookies.filter {
            $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
                && $0.path == "/"
        }
    }
}

struct T3CompatView: View {
    @ObservedObject var manager: T3CompatManager
    let onBack: () -> Void

    @State private var webError: String?
    @State private var reloadID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Label(
                        String(localized: "t3.back", defaultValue: "Workbench"),
                        systemImage: "chevron.left"
                    )
                }
                .buttonStyle(.borderless)
                Divider().frame(height: 18)
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text(String(localized: "t3.title", defaultValue: "Local Agent"))
                    .font(.headline)
                Spacer()
                if case .starting = manager.state {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(.bar)
            Divider()

            content
        }
        .frame(
            minWidth: WorkbenchLayoutMetrics.minimumWindowWidth,
            minHeight: WorkbenchLayoutMetrics.minimumWindowHeight
        )
        .task { await manager.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch manager.state {
        case .idle, .starting:
            VStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "t3.starting", defaultValue: "Starting Local Agent…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let origin):
            ZStack {
                T3WebView(origin: origin, manager: manager) { message in
                    webError = message
                }
                .id(reloadID)
                if let webError {
                    failureView(webError) {
                        self.webError = nil
                        reloadID = UUID()
                    }
                    .background(.regularMaterial)
                }
            }
        case .failed(let message):
            failureView(message) {
                Task { await manager.retry() }
            }
        }
    }

    private func failureView(_ message: String, retry: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label(
                String(localized: "t3.error.title", defaultValue: "Local Agent unavailable"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(message)
        } actions: {
            Button(String(localized: "t3.retry", defaultValue: "Retry"), action: retry)
            Button(String(localized: "t3.back", defaultValue: "Workbench"), action: onBack)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct T3WebView: NSViewRepresentable {
    let origin: URL
    let manager: T3CompatManager
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(origin: origin, manager: manager, onFailure: onFailure)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.load(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let origin: URL
        let manager: T3CompatManager
        let onFailure: (String) -> Void

        init(origin: URL, manager: T3CompatManager, onFailure: @escaping (String) -> Void) {
            self.origin = origin
            self.manager = manager
            self.onFailure = onFailure
        }

        func load(_ webView: WKWebView) {
            Task {
                do {
                    let store = webView.configuration.websiteDataStore.httpCookieStore
                    let storedCookies = await withCheckedContinuation { continuation in
                        store.getAllCookies { continuation.resume(returning: $0) }
                    }
                    let currentCookies = T3CookiePolicy.cookies(
                        for: origin,
                        from: storedCookies
                    )
                    if !(await manager.hasValidBrowserSession(currentCookies)) {
                        let cookies = try await manager.browserSessionCookies()
                        for cookie in cookies {
                            await withCheckedContinuation { continuation in
                                store.setCookie(cookie) { continuation.resume() }
                            }
                        }
                    }
                    webView.load(URLRequest(url: origin))
                } catch {
                    onFailure(error.localizedDescription)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            switch T3NavigationPolicy.disposition(for: url, origin: origin) {
            case .embedded:
                decisionHandler(.allow)
            case .external:
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            case .blocked:
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else { return nil }
            switch T3NavigationPolicy.disposition(for: url, origin: origin) {
            case .embedded:
                webView.load(navigationAction.request)
            case .external:
                NSWorkspace.shared.open(url)
            case .blocked:
                break
            }
            return nil
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            load(webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onFailure(error.localizedDescription)
        }
    }
}
