import AppKit
import WebKit

final class WebTestDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var web: WKWebView!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 850),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Trump Switcher — тест веб-редактора"
        web = WKWebView(frame: NSRect(x: 0, y: 45, width: 900, height: 805))
        web.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(web)
        let fixture = Bundle.main.url(forResource: "web-editor", withExtension: "html")!
        web.loadFileURL(fixture, allowingReadAccessTo: fixture.deletingLastPathComponent())
        let button = NSButton(title: "Активировать тестовый AXGroup", target: self, action: #selector(activateEditor))
        button.frame = NSRect(x: 20, y: 5, width: 400, height: 30)
        window.contentView!.addSubview(button)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
    @objc private func activateEditor() {
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeFirstResponder(web)
        web.evaluateJavaScript("document.getElementById('group').focus()")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = WebTestDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
