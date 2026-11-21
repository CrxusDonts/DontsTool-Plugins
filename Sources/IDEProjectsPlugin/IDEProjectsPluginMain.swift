import DontsToolPluginSDK
import IDEProjectsCore

@main
struct IDEProjectsPluginMain {
    static func main() async {
        let engine = IDEProjectsEngine()
        await SidecarRuntime.runDaemon(engine: engine, threadName: "com.donts.idea-projects.stdin")
    }
}
