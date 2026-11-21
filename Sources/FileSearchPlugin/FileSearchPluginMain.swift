import DontsToolPluginSDK
import FileSearchCore

@main
struct FileSearchPluginMain {
    static func main() async {
        let engine = FileSearchEngine()
        await SidecarRuntime.runDaemon(engine: engine, threadName: "com.donts.file-search.stdin")
    }
}
