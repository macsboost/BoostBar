// Loads a screen saver page in WKWebView exactly like the .saver does (loadHTMLString, the same message
// handler), waits for "ready" or an error, and prints a snapshot as base64 — to check the page in Apple's WebKit.
// usage: swift tools/webkit_check.swift out/saver.html '{"count":4}'
import Cocoa
import WebKit

final class Relay: NSObject, WKScriptMessageHandler {
    var ready = false
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        print("PAGE SAYS:", m.body)
        if "\(m.body)" == "ready" { ready = true }
    }
}
let args = CommandLine.arguments
let html = try! String(contentsOfFile: args[1], encoding: .utf8)
let cfg = args.count > 2 ? args[2] : "{}"
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
let relay = Relay()
let conf = WKWebViewConfiguration()
conf.userContentController.add(relay, name: "boostbar")
conf.userContentController.addUserScript(WKUserScript(source: """
window.SAVER_CONFIG=\(cfg);
['log','warn','error'].forEach(k=>{const o=console[k];console[k]=(...a)=>{try{window.webkit.messageHandlers.boostbar.postMessage(k+': '+a.join(' '))}catch(e){};o.apply(console,a)}});
""", injectionTime: .atDocumentStart, forMainFrameOnly: true))
let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
let web = WKWebView(frame: w.contentView!.bounds, configuration: conf)
web.setValue(false, forKey: "drawsBackground")
w.backgroundColor = .black
w.contentView!.addSubview(web)
w.orderFrontRegardless()
web.loadHTMLString(html, baseURL: nil)
let start = Date()
while Date().timeIntervalSince(start) < 25 && !(relay.ready && Date().timeIntervalSince(start) > 6) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
}
print("READY:", relay.ready, "after", Int(Date().timeIntervalSince(start)), "s")
web.evaluateJavaScript("(()=>{const c=document.createElement('canvas');const g=c.getContext('webgl2')||c.getContext('webgl');return g?('webgl ok: '+g.getParameter(g.VERSION)):'NO WEBGL'})()") { r, e in print("WEBGL:", r ?? "nil", e.map { "\($0)" } ?? "") }
RunLoop.main.run(until: Date().addingTimeInterval(1))
var done = false
web.takeSnapshot(with: nil) { img, _ in
    if let img, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
       let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
        print("IMG_BEGIN webkit.jpg"); print(jpg.base64EncodedString()); print("IMG_END")
    }
    done = true
}
while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
