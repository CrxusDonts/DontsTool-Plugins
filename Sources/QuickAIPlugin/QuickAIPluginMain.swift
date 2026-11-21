import DontsToolPluginSDK
import QuickAICore

@main
struct QuickAIPluginMain {
    static func main() async {
        let engine = QuickAIEngine()
        await SidecarRuntime.runDaemon(engine: engine, threadName: "com.donts.quick-ai.stdin")
    }
}
