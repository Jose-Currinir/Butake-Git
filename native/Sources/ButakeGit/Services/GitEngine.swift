import Foundation

struct EngineFailure: Codable, LocalizedError { var code: String; var detail: String; var errorDescription: String? { detail } }
private struct EngineResponse<T: Decodable>: Decodable { var ok: Bool; var value: T?; var error: EngineFailure? }

actor GitEngine {
    let executableURL: URL
    init(executable: URL = GitEngine.executable) { self.executableURL = executable }
    static var executable: URL {
        if let override = ProcessInfo.processInfo.environment["BUTAKE_GIT_ENGINE"] { return URL(fileURLWithPath: override) }
        return Bundle.main.resourceURL!.appendingPathComponent("butake-git-engine")
    }
    func call<T: Decodable>(_ parameters: [String: Any], as: T.Type = T.self) async throws -> T {
        let input = try JSONSerialization.data(withJSONObject: parameters)
        let executable = executableURL
        let output: Data = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            let stdout = Pipe(); let stderr = Pipe(); let stdin = Pipe()
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
            async let errors = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let diagnostic = await errors
            if process.terminationStatus != 0 && output.isEmpty { throw EngineFailure(code: "engine", detail: String(data: diagnostic, encoding: .utf8) ?? L("engineFailed")) }
            return output
        }.value
        let response = try JSONDecoder().decode(EngineResponse<T>.self, from: output)
        if let value = response.value, response.ok { return value }
        throw response.error ?? EngineFailure(code: "engine", detail: L("engineFailed"))
    }
    func query(_ root: String, _ args: [String]) async throws -> String { try await call(["method": "query", "path": root, "args": args]) }
}
