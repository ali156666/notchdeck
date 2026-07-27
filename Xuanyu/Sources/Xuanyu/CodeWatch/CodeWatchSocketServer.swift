// CodeWatch：接收 CLI hook 事件的 Unix Domain Socket 服务器。
// 简化自 CodeIsland (https://github.com/wxtsky/CodeIsland, MIT, Copyright (c) 2026 wxtsky)
// 的 Sources/CodeIsland/HookServer.swift。上游支持阻塞式审批/提问回传，
// 这里是纯监控：所有事件立即回 {}，绝不让 CLI 等待。
import CodeWatchCore
import Foundation
import Network

final class CodeWatchSocketServer: @unchecked Sendable {
    static func defaultSocketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["XUANYU_CODEWATCH_SOCKET"], !override.isEmpty {
            return override
        }
        return "/tmp/xuanyu-codewatch-\(getuid()).sock"
    }

    private let socketPath: String
    private let onEvent: @Sendable (HookEvent) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "xuanyu.codewatch.socket")
    private static let maxRequestBytes = 5 * 1024 * 1024

    init(socketPath: String = CodeWatchSocketServer.defaultSocketPath(),
         onEvent: @escaping @Sendable (HookEvent) -> Void) {
        self.socketPath = socketPath
        self.onEvent = onEvent
    }

    func start() throws {
        unlink(socketPath)
        let oldMask = umask(0o077)
        defer { umask(oldMask) }

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [socketPath] state in
            if case .ready = state {
                chmod(socketPath, 0o700)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        unlink(socketPath)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveAll(connection, accumulated: Data())
    }

    /// 客户端（hook 脚本里的 nc）发完 JSON 后半关闭写端；读到 EOF 即整条消息。
    private func receiveAll(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestBytes {
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                self.process(buffer, on: connection)
                return
            }
            self.receiveAll(connection, accumulated: buffer)
        }
    }

    private func process(_ data: Data, on connection: NWConnection) {
        defer {
            // 无论事件是否有效都回 {}：hook 端的 nc 等到响应才退出
            connection.send(content: Data("{}".utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        guard !data.isEmpty, let event = HookEvent(from: data) else { return }
        onEvent(event)
    }
}
