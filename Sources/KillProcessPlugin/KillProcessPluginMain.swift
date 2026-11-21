import DontsToolPluginSDK
import KillProcessCore

@main
struct KillProcessPluginMain {
    static func main() async {
        let excludedPIDs = SidecarRuntime.excludedHostPIDs()
        let service = SystemProcessService(excludedPIDs: excludedPIDs)
        let engine = KillProcessEngine(service: service)
        await SidecarRuntime.runDaemon(engine: engine, threadName: "com.donts.kill-process.stdin")
    }
}
