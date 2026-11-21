import DontsToolPluginSDK
import TerminalFinderCore

@main
struct TerminalFinderPluginMain {
    static func main() async {
        let engine = TerminalFinderEngine()
        await SidecarRuntime.runDaemon(engine: engine, threadName: "com.donts.terminal-finder.stdin")
    }
}
