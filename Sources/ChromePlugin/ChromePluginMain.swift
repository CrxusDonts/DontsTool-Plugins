import ChromeCore
import DontsToolPluginSDK

@main
struct ChromePluginMain {
    static func main() async {
        let engine = ChromeEngine()
        await SidecarRuntime.runDaemon(engine: engine, threadName: "com.donts.chrome.stdin")
    }
}
