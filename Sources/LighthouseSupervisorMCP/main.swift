import Foundation
import LighthouseSupervisor

// Stdio MCP server for the supervisor session. Spawned by `claude --mcp-config`,
// never by the app. It READS config.json, hook-events.jsonl and proposals.json from
// $LIGHTHOUSE_CONFIG_DIR (or the Application Support default); its only WRITE is a
// proposal file into supervisor-inbox/ beside them, which the app validates again.
// Protocol replies go to stdout; stdout stays pure JSON-RPC.

let directory = FileSnapshotSource.defaultDirectory()
let server = MCPServer(
    source: FileSnapshotSource(directory: directory),
    submitter: ProposalInbox(configDirectory: directory))

while let line = readLine(strippingNewline: true) {
    if let reply = server.handle(line: line) {
        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
}
