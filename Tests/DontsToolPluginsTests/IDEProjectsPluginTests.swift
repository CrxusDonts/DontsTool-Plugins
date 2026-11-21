import DontsToolPluginSDK
import Foundation
import IDEProjectsCore
import XCTest

private actor MockIDELauncher: IDEProjectOpening {
    var opened: [(project: URL, app: URL)] = []

    func openProject(at project: URL, using application: URL) async throws {
        opened.append((project, application))
    }
}

final class IDEProjectsPluginTests: XCTestCase {
    func testParseRecentProjectsXMLAndRejectsDTD() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let xml = """
        <application>
          <component name="RecentProjectsManager">
            <option name="additionalInfo">
              <map>
                <entry key="$USER_HOME$/code/alpha">
                  <value>
                    <RecentProjectMetaInfo>
                      <option name="activationTimestamp" value="1000" />
                    </RecentProjectMetaInfo>
                  </value>
                </entry>
                <entry key="$USER_HOME$/code/beta">
                  <value>
                    <RecentProjectMetaInfo>
                      <option name="activationTimestamp" value="2000" />
                      <option name="customProjectName" value="Beta Service" />
                    </RecentProjectMetaInfo>
                  </value>
                </entry>
                <entry key="$USER_HOME$/code/hidden">
                  <value>
                    <RecentProjectMetaInfo hidden="true">
                      <option name="activationTimestamp" value="3000" />
                    </RecentProjectMetaInfo>
                  </value>
                </entry>
              </map>
            </option>
          </component>
        </application>
        """

        let parsed = try IDERecentProjectsParser.parse(Data(xml.utf8), homeDirectory: home)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].name, "Beta Service")
        XCTAssertEqual(parsed[0].url.path, "/Users/tester/code/beta")
        XCTAssertEqual(parsed[1].name, "alpha")
        XCTAssertEqual(parsed[1].url.path, "/Users/tester/code/alpha")

        let xxe = "<!DOCTYPE foo [<!ENTITY xxe \"bar\">]><application/>"
        XCTAssertThrowsError(try IDERecentProjectsParser.parse(Data(xxe.utf8), homeDirectory: home))
    }

    func testDiscoverySearchActionsAndExecute() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("idea-plugin-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
        let appURL = appsDir.appendingPathComponent("IntelliJ IDEA.app", isDirectory: true)
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: appURL.appendingPathComponent("Contents/MacOS/idea"))
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.jetbrains.intellij</string>
          <key>CFBundleShortVersionString</key><string>2025.1.2</string>
          <key>CFBundleName</key><string>IntelliJ IDEA</string>
        </dict></plist>
        """
        try Data(plist.utf8).write(to: appURL.appendingPathComponent("Contents/Info.plist"))

        let projA = root.appendingPathComponent("projects/demo-api", isDirectory: true)
        let projB = root.appendingPathComponent("projects/other-web", isDirectory: true)
        try fm.createDirectory(at: projA, withIntermediateDirectories: true)
        try fm.createDirectory(at: projB, withIntermediateDirectories: true)

        let jbDir = root.appendingPathComponent("JetBrains", isDirectory: true)
        let optionsDir = jbDir.appendingPathComponent("IntelliJIdea2025.1/options", isDirectory: true)
        try fm.createDirectory(at: optionsDir, withIntermediateDirectories: true)
        let xml = """
        <application><component name="RecentProjectsManager"><option name="additionalInfo"><map>
          <entry key="\(projA.path)"><value><RecentProjectMetaInfo><option name="activationTimestamp" value="200" /></RecentProjectMetaInfo></value></entry>
          <entry key="\(projB.path)"><value><RecentProjectMetaInfo><option name="activationTimestamp" value="100" /></RecentProjectMetaInfo></value></entry>
        </map></option></component></application>
        """
        try Data(xml.utf8).write(to: optionsDir.appendingPathComponent("recentProjects.xml"))

        let discovery = IDEProjectDiscovery(
            homeDirectory: root,
            jetBrainsDirectory: jbDir,
            applicationRoots: [appsDir],
            includeLaunchServices: false
        )
        let launcher = MockIDELauncher()
        let engine = IDEProjectsEngine(discovery: discovery, launcher: launcher)

        let searchResult = await engine.search(PluginSearchParams(keyword: "idea", query: "demo-api"))
        XCTAssertEqual(searchResult.items.count, 1)
        let item = try XCTUnwrap(searchResult.items.first)
        XCTAssertEqual(item.title, "demo-api")
        XCTAssertEqual(item.score, 3000)
        XCTAssertEqual(item.actions.map(\.id), [
            "idea.project.open",
            "idea.project.reveal",
            "idea.project.copyPath",
            "idea.project.openInTerminal"
        ])
        XCTAssertEqual(item.actions.last?.effect?.kind, "openInTerminal")

        // Execute open action
        let openAction = try XCTUnwrap(item.actions.first)
        let execResult = await engine.execute(PluginExecuteParams(
            actionId: openAction.id,
            payload: openAction.payload ?? [:]
        ))
        XCTAssertNil(execResult.error)
        let opened = await launcher.opened
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.project.standardizedFileURL.path, projA.standardizedFileURL.path)

        // Manual directory path
        let manualResult = await engine.search(PluginSearchParams(keyword: "idea", query: projB.path))
        XCTAssertEqual(manualResult.items.first?.title, "other-web")
    }
}
