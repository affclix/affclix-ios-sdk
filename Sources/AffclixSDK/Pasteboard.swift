import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

/// How the SDK picks up an iOS deferred deep link. A branded link opened on an
/// iPhone without the app shows a "Continue to the App Store" page (when the
/// app has iOS deferred deep linking on in the dashboard); the user's tap
/// copies a one-time link, which the app reads on first launch.
public enum DeferredDeepLinking {
    /// No deferred deep links.
    case off
    /// On first launch the SDK reads the clipboard when it holds a web link
    /// (iOS asks the user "Allow Paste"; clipboards without a link are left
    /// unread, so no prompt).
    case automatic
    /// The app passes clipboard text from its own `UIPasteControl` (no paste
    /// prompt) to `Affclix.resolveDeferredDeepLink(_:)`. The install waits up
    /// to `deferredDeepLinkTimeout` for it.
    case manual
}

/// The clipboard, for deferred deep links.
protocol PasteboardProvider {
    /// The clipboard's text when it probably holds a web link, else nil.
    /// Detecting the link does not read the clipboard, so iOS only asks the
    /// user to allow the paste when there is a link to read.
    func probableLink(_ completion: @escaping (String?) -> Void)
    /// Empties the clipboard if it has not changed since `probableLink` read it.
    func clearIfUnchanged()
}

final class SystemPasteboard: PasteboardProvider {
    #if canImport(UIKit) && os(iOS)
    private var readAt: Int?

    func probableLink(_ completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            let board = UIPasteboard.general
            guard board.hasStrings || board.hasURLs else { return completion(nil) }
            let read = {
                self.readAt = board.changeCount
                completion(board.url?.absoluteString ?? board.string)
            }
            if #available(iOS 14, *) {
                board.detectPatterns(for: [.probableWebURL]) { result in
                    DispatchQueue.main.async {
                        if case .success(let found) = result, found.contains(.probableWebURL) {
                            read()
                        } else {
                            completion(nil)
                        }
                    }
                }
            } else {
                read()
            }
        }
    }

    func clearIfUnchanged() {
        DispatchQueue.main.async {
            let board = UIPasteboard.general
            if let at = self.readAt, board.changeCount == at { board.items = [] }
            self.readAt = nil
        }
    }
    #else
    func probableLink(_ completion: @escaping (String?) -> Void) { completion(nil) }
    func clearIfUnchanged() {}
    #endif
}
