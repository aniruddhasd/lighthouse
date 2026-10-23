import Foundation
import LighthouseSupervisor

// Stdio MCP server for the supervisor session. Spawned by `claude --mcp-config`,
// never by the app. Read-only: it reads config.json and hook-events.jsonl from
// $LIGHTHOUSE_CONFIG_DIR (or the Application Support default) and writes only
// protocol replies to stdout. Diagnostics go to stderr; stdout stays pure JSON-RPC.

let server = MCPServer(source: FileSnapshotSource(directory: FileSnapshotSource.defaultDirectory()))

while let line = readLine(strippingNewline: true) {
    if let reply = server.handle(line: line) {
        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
}
