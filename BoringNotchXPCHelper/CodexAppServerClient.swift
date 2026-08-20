import Foundation

private enum CodexAppServerError: LocalizedError {
    case executableNotFound
    case timedOut
    case endOfStream
    case invalidResponse
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "找不到 Codex 命令行程序"
        case .timedOut:
            return "Codex 额度读取超时"
        case .endOfStream:
            return "Codex app-server 连接已关闭"
        case .invalidResponse:
            return "Codex 返回了无法识别的数据"
        case let .remote(message):
            return message
        }
    }
}

private final class JSONLineReader {
    private let handle: FileHandle
    private let condition = NSCondition()
    private var buffer = Data()
    private var lines: [Data] = []
    private var reachedEnd = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] fileHandle in
            self?.receive(fileHandle.availableData)
        }
    }

    deinit {
        handle.readabilityHandler = nil
    }

    func nextLine(timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while lines.isEmpty && !reachedEnd {
            if !condition.wait(until: deadline) {
                condition.unlock()
                throw CodexAppServerError.timedOut
            }
        }

        if let line = lines.first {
            lines.removeFirst()
            condition.unlock()
            return line
        }

        condition.unlock()
        throw CodexAppServerError.endOfStream
    }

    private func receive(_ data: Data) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }

        guard !data.isEmpty else {
            reachedEnd = true
            return
        }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            lines.append(line)
        }
    }
}

final class CodexAppServerClient {
    private let responseTimeout: TimeInterval = 8

    func readUsage() throws -> String {
        guard let executablePath = findCodexExecutable() else {
            throw CodexAppServerError.executableNotFound
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        try process.run()
        let reader = JSONLineReader(handle: outputPipe.fileHandleForReading)

        try send(
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "boring-notch",
                        "title": "Boring Notch",
                        "version": "1.0"
                    ]
                ]
            ],
            to: inputPipe.fileHandleForWriting
        )
        _ = try response(id: 1, from: reader)

        try send(
            [
                "method": "initialized",
                "params": [:]
            ],
            to: inputPipe.fileHandleForWriting
        )

        try send(
            [
                "id": 2,
                "method": "account/read",
                "params": ["refreshToken": false]
            ],
            to: inputPipe.fileHandleForWriting
        )
        let accountResponse = try response(id: 2, from: reader)
        guard let accountResult = accountResponse["result"] as? [String: Any] else {
            throw CodexAppServerError.invalidResponse
        }

        var payload: [String: Any] = ["account": accountResult]
        let account = accountResult["account"]
        guard account != nil, !(account is NSNull) else {
            return try encode(payload)
        }

        try send(
            [
                "id": 3,
                "method": "account/rateLimits/read",
                "params": [:]
            ],
            to: inputPipe.fileHandleForWriting
        )
        let rateLimitsResponse = try response(id: 3, from: reader)
        guard let rateLimitsResult = rateLimitsResponse["result"] as? [String: Any] else {
            throw CodexAppServerError.invalidResponse
        }
        payload["rateLimits"] = rateLimitsResult

        return try encode(payload)
    }

    private func response(id: Int, from reader: JSONLineReader) throws -> [String: Any] {
        while true {
            let data = try reader.nextLine(timeout: responseTimeout)
            guard !data.isEmpty,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            guard let responseID = object["id"] as? NSNumber,
                  responseID.intValue == id else {
                continue
            }

            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Codex 请求失败"
                throw CodexAppServerError.remote(message)
            }
            return object
        }
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        handle.write(data)
        handle.write(Data([10]))
    }

    private func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw CodexAppServerError.invalidResponse
        }
        return string
    }

    private func findCodexExecutable() -> String? {
        var candidates: [String] = []

        if let configuredPath = ProcessInfo.processInfo.environment["CODEX_BINARY_PATH"],
           !configuredPath.isEmpty {
            candidates.append(configuredPath)
        }

        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex").path
        ])

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { directory in
                URL(fileURLWithPath: String(directory))
                    .appendingPathComponent("codex").path
            })
        }

        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        })
    }
}
