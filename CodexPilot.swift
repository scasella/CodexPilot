import SwiftUI
import Foundation
import Network

// MARK: - Models

struct CodexThread: Identifiable {
    let id: String
    var name: String
    var status: String
    var archived: Bool
    var modelProvider: String?
    var tokenUsage: Int?
    var cwd: String?
    var createdAt: Date?
}

struct ServerEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let method: String
    let summary: String
}

struct DisplayItem: Identifiable {
    let id: String
    let turnId: String
    let type: String
    var text: String
    var status: String?
    var command: String?
    var files: [String]?
    var exitCode: Int?
}

struct FairyIdentity {
    let name: String
    let emoji: String // SF Symbol name
    let color: Color
    let colorName: String
}

enum FairyState: String {
    case sleeping, idle, thinking, working, waiting, done, error
}

struct FairyPreview: Identifiable {
    let id: String // threadId
    var identity: FairyIdentity
    var state: FairyState
    var previewText: String
    var threadName: String?
    var tokenUsage: Int?
    var lastActivity: Date
    var isSummoned: Bool
    var model: String?
}

enum ContentMode: Hashable {
    case empty
    case threadDetail
    case fairyGarden
    case eventLog
}

// MARK: - Slack Theme

enum SlackTheme {
    // Sidebar (aubergine)
    static let sidebarBG = Color(red: 0.29, green: 0.08, blue: 0.29)
    static let sidebarHover = Color(red: 0.36, green: 0.28, blue: 0.36)
    static let sidebarActive = Color(red: 0.07, green: 0.39, blue: 0.64)
    static let sidebarText = Color.white
    static let sidebarMuted = Color.white.opacity(0.55)

    // Content area (dark)
    static let contentBG = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let contentText = Color(red: 0.82, green: 0.82, blue: 0.83)
    static let brightText = Color(red: 0.91, green: 0.91, blue: 0.91)
    static let contentHover = Color.white.opacity(0.04)

    // Accents
    static let presenceGreen = Color(red: 0.22, green: 0.59, blue: 0.55)
    static let mentionBadge = Color(red: 0.88, green: 0.12, blue: 0.35)
    static let linkBlue = Color(red: 0.11, green: 0.61, blue: 0.82)

    // Composer
    static let composerBorder = Color.white.opacity(0.15)
    static let composerBG = Color.white.opacity(0.05)

    // Dimensions
    static let sidebarWidth: CGFloat = 220
    static let menuBarWidth: CGFloat = 660
    static let menuBarHeight: CGFloat = 500
    static let popoutWidth: CGFloat = 900
    static let popoutHeight: CGFloat = 600
    static let headerHeight: CGFloat = 50
    static let avatarSize: CGFloat = 36
}

// MARK: - Fairy Identity Generator

struct FairyIdentityGenerator {
    private static let names = [
        "Wisp", "Ember", "Ripple", "Petal", "Glint", "Fern", "Spark", "Mist", "Drift", "Bloom",
        "Flicker", "Thistle", "Zephyr", "Luna", "Ivy", "Cedar", "Nimbus", "Echo", "Sage", "Coral",
        "Dusk", "Clover", "Frost", "Lark", "Moss", "Rue", "Glow", "Breeze", "Wren", "Vale",
    ]
    private static let emojis = [
        "sparkles", "flame.fill", "drop.fill", "leaf.fill", "bolt.fill",
        "moon.stars.fill", "wind", "cloud.fill", "star.fill", "wand.and.stars",
    ]
    private static let colors: [(Color, String)] = [
        (.purple, "purple"), (.cyan, "cyan"), (.orange, "orange"), (.pink, "pink"), (.mint, "mint"),
        (.indigo, "indigo"), (.teal, "teal"), (.yellow, "yellow"), (.blue, "blue"), (.red, "red"),
    ]

    static func identity(for threadId: String) -> FairyIdentity {
        var hash: UInt64 = 5381
        for byte in threadId.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let nameIdx = Int(hash % UInt64(names.count))
        let emojiIdx = Int((hash / 7) % UInt64(emojis.count))
        let colorIdx = Int((hash / 13) % UInt64(colors.count))
        return FairyIdentity(
            name: names[nameIdx],
            emoji: emojis[emojiIdx],
            color: colors[colorIdx].0,
            colorName: colors[colorIdx].1
        )
    }
}

// MARK: - Raw WebSocket Client (no Sec-WebSocket-Extensions)

class RawWebSocket {
    private var connection: NWConnection?
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "ws", qos: .userInitiated)

    var onMessage: ((String) -> Void)?
    var onConnect: (() -> Void)?
    var onDisconnect: ((String) -> Void)?

    private var handshakeComplete = false
    private var receiveBuffer = Data()

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func connect() {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.performHandshake()
            case .failed(let err):
                DispatchQueue.main.async { self?.onDisconnect?("Failed: \(err)") }
            case .cancelled:
                DispatchQueue.main.async { self?.onDisconnect?("Cancelled") }
            default: break
            }
        }
        connection?.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        handshakeComplete = false
        receiveBuffer = Data()
    }

    func send(_ text: String) {
        guard handshakeComplete else { return }
        let frame = encodeTextFrame(text)
        connection?.send(content: frame, completion: .contentProcessed({ _ in }))
    }

    private func performHandshake() {
        var keyBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &keyBytes)
        let key = Data(keyBytes).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        connection?.send(content: request.data(using: .utf8)!, completion: .contentProcessed({ [weak self] err in
            if let err {
                DispatchQueue.main.async { self?.onDisconnect?("Handshake send failed: \(err)") }
                return
            }
            self?.readHandshakeResponse()
        }))
    }

    private func readHandshakeResponse() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, err in
            guard let self else { return }
            if let err {
                DispatchQueue.main.async { self.onDisconnect?("Handshake read failed: \(err)") }
                return
            }
            guard let data else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("101") && text.lowercased().contains("upgrade") {
                self.handshakeComplete = true
                DispatchQueue.main.async { self.onConnect?() }
                self.startReading()
            } else {
                DispatchQueue.main.async { self.onDisconnect?("Handshake rejected: \(text.prefix(100))") }
            }
        }
    }

    private func encodeTextFrame(_ text: String) -> Data {
        let payload = Array(text.utf8)
        var frame = Data()
        frame.append(0x81)
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len) | 0x80)
        } else if len < 65536 {
            frame.append(126 | 0x80)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127 | 0x80)
            for i in (0..<8).reversed() { frame.append(UInt8((len >> (i * 8)) & 0xFF)) }
        }
        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
        frame.append(contentsOf: mask)
        for (i, byte) in payload.enumerated() { frame.append(byte ^ mask[i % 4]) }
        return frame
    }

    private func startReading() {
        connection?.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] data, _, _, err in
            guard let self else { return }
            if let err {
                DispatchQueue.main.async { self.onDisconnect?("Read error: \(err)") }
                return
            }
            if let data {
                self.receiveBuffer.append(data)
                self.processFrames()
            }
            self.startReading()
        }
    }

    private func processFrames() {
        while receiveBuffer.count >= 2 {
            let b0 = receiveBuffer[0]
            let b1 = receiveBuffer[1]
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var payloadLen = Int(b1 & 0x7F)
            var offset = 2
            if payloadLen == 126 {
                guard receiveBuffer.count >= 4 else { return }
                payloadLen = Int(receiveBuffer[2]) << 8 | Int(receiveBuffer[3])
                offset = 4
            } else if payloadLen == 127 {
                guard receiveBuffer.count >= 10 else { return }
                payloadLen = 0
                for i in 0..<8 { payloadLen = (payloadLen << 8) | Int(receiveBuffer[2 + i]) }
                offset = 10
            }
            var maskKey: [UInt8] = []
            if masked {
                guard receiveBuffer.count >= offset + 4 else { return }
                maskKey = Array(receiveBuffer[offset..<offset+4])
                offset += 4
            }
            guard receiveBuffer.count >= offset + payloadLen else { return }
            var payload = Array(receiveBuffer[offset..<offset+payloadLen])
            if masked { for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] } }
            receiveBuffer = Data(receiveBuffer[(offset + payloadLen)...])
            switch opcode {
            case 0x1:
                if let text = String(bytes: payload, encoding: .utf8) {
                    DispatchQueue.main.async { self.onMessage?(text) }
                }
            case 0x8:
                DispatchQueue.main.async { self.onDisconnect?("Server closed connection") }
                return
            case 0x9:
                var pong = Data([0x8A])
                pong.append(UInt8(payload.count) | 0x80)
                var mask = [UInt8](repeating: 0, count: 4)
                _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
                pong.append(contentsOf: mask)
                for (i, byte) in payload.enumerated() { pong.append(byte ^ mask[i % 4]) }
                connection?.send(content: pong, completion: .contentProcessed({ _ in }))
            default: break
            }
        }
    }
}

// MARK: - Connection Manager

@Observable
class CodexConnection {
    // Thread list state
    var isConnected = false
    var isConnecting = false
    var threads: [CodexThread] = []
    var loadedThreadIds: Set<String> = []
    var events: [ServerEvent] = []
    var serverAddress = "ws://127.0.0.1:8080"
    var lastError: String?
    var hasActiveTurn = false
    var activeThreadId: String?

    // Detail view state
    var selectedThreadId: String?
    var detailItems: [DisplayItem] = []
    var detailThreadName: String = ""
    var detailTokens: Int?
    var detailModel: String?
    var isLoadingDetail = false
    var isTurnActive = false
    var streamingItemId: String?
    var promptText = ""

    // Account & rate limits (v0.3.0)
    var accountEmail: String?
    var accountPlan: String?
    var rateLimitUsedPercent: Int?
    var rateLimitResetsAt: Date?
    var showArchivedThreads = false
    var isEditingName = false
    var editingName = ""

    // Fairy Garden (v0.4.0)
    var fairyPreviews: [String: FairyPreview] = [:]
    var summonText = ""
    var isSummoning = false

    // v0.5.0 Slack layout
    var contentMode: ContentMode = .empty
    var showSummonInput = false
    var threadsCollapsed = false
    var fairiesCollapsed = false

    var sortedFairies: [FairyPreview] {
        Array(fairyPreviews.values).sorted { a, b in
            let aActive = a.state == .working || a.state == .thinking || a.state == .waiting
            let bActive = b.state == .working || b.state == .thinking || b.state == .waiting
            if aActive != bActive { return aActive }
            return a.lastActivity > b.lastActivity
        }
    }

    var activeFairyCount: Int {
        fairyPreviews.values.filter { $0.state == .working || $0.state == .thinking || $0.state == .waiting }.count
    }

    private var ws: RawWebSocket?
    private var requestId = 0
    private var pendingRequests: [Int: String] = [:]
    private var reconnectTimer: Timer?
    private var refreshTimer: Timer?
    private var pendingSummonPrompt: String?

    // MARK: - Connection lifecycle

    func connect() {
        guard !isConnecting, !isConnected else { return }
        isConnecting = true
        lastError = nil

        guard let comps = URLComponents(string: serverAddress),
              let host = comps.host,
              let port = comps.port else {
            lastError = "Invalid URL — use ws://host:port"
            isConnecting = false
            return
        }

        ws = RawWebSocket(host: host, port: UInt16(port))

        ws?.onConnect = { [weak self] in
            guard let self else { return }
            let rid = self.nextId()
            self.pendingRequests[rid] = "initialize"
            self.sendRequest(id: rid, method: "initialize", params: [
                "clientInfo": ["name": "CodexPilot", "version": "0.4.1"] as [String: Any],
            ])
        }

        ws?.onMessage = { [weak self] text in self?.handleIncoming(text) }

        ws?.onDisconnect = { [weak self] reason in
            guard let self else { return }
            self.isConnected = false
            self.isConnecting = false
            self.lastError = reason
            self.refreshTimer?.invalidate()
            self.scheduleReconnect()
        }

        ws?.connect()
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        ws?.disconnect()
        ws = nil
        isConnected = false
        isConnecting = false
        pendingRequests.removeAll()
        threads = []
        loadedThreadIds = []
        hasActiveTurn = false
        activeThreadId = nil
        accountEmail = nil
        accountPlan = nil
        rateLimitUsedPercent = nil
        rateLimitResetsAt = nil
        fairyPreviews = [:]
        pendingSummonPrompt = nil
        isSummoning = false
        deselectThread()
    }

    // MARK: - Fairy helpers

    func updateFairyState(_ threadId: String, _ state: FairyState) {
        if var preview = fairyPreviews[threadId] {
            preview.state = state
            preview.lastActivity = Date()
            fairyPreviews[threadId] = preview
        } else {
            let identity = FairyIdentityGenerator.identity(for: threadId)
            let thread = threads.first { $0.id == threadId }
            fairyPreviews[threadId] = FairyPreview(
                id: threadId, identity: identity, state: state,
                previewText: "", threadName: thread?.name,
                tokenUsage: thread?.tokenUsage, lastActivity: Date(),
                isSummoned: false, model: nil
            )
        }
    }

    func appendFairyPreview(_ threadId: String, delta: String) {
        if var preview = fairyPreviews[threadId] {
            preview.previewText += delta
            if preview.previewText.count > 120 {
                preview.previewText = String(preview.previewText.suffix(120))
            }
            preview.state = .working
            preview.lastActivity = Date()
            fairyPreviews[threadId] = preview
        } else {
            updateFairyState(threadId, .working)
            fairyPreviews[threadId]?.previewText = String(delta.suffix(120))
        }
    }

    func summonFairy(prompt: String) {
        guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSummoning = true
        pendingSummonPrompt = prompt
        let rid = nextId()
        pendingRequests[rid] = "thread/start"
        sendRequest(id: rid, method: "thread/start", params: [
            "model": "gpt-5.3-codex-spark"
        ])
    }

    func refresh() {
        guard isConnected else { return }
        requestThreadList()
        requestLoadedThreads()
        requestRateLimits()
    }

    // MARK: - Thread detail

    func selectThread(_ thread: CodexThread) {
        selectedThreadId = thread.id
        detailThreadName = thread.name
        detailModel = thread.modelProvider
        detailTokens = thread.tokenUsage
        detailItems = []
        isLoadingDetail = true
        isTurnActive = false
        streamingItemId = nil
        promptText = ""
        contentMode = .threadDetail

        let rid = nextId()
        pendingRequests[rid] = "thread/resume"
        sendRequest(id: rid, method: "thread/resume", params: ["threadId": thread.id])
    }

    func deselectThread() {
        selectedThreadId = nil
        detailItems = []
        detailThreadName = ""
        detailTokens = nil
        detailModel = nil
        isLoadingDetail = false
        isTurnActive = false
        streamingItemId = nil
        promptText = ""
        contentMode = .empty
    }

    func sendPrompt() {
        guard let threadId = selectedThreadId, !promptText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let text = promptText
        promptText = ""

        // Add user message to display immediately
        let itemId = UUID().uuidString
        detailItems.append(DisplayItem(id: itemId, turnId: "pending", type: "userMessage", text: text))

        let rid = nextId()
        pendingRequests[rid] = "turn/start"
        sendRequest(id: rid, method: "turn/start", params: [
            "threadId": threadId,
            "input": [
                ["type": "text", "text": text, "textElements": [Any]()] as [String: Any]
            ],
        ])
        isTurnActive = true
    }

    // MARK: - Requests

    private func nextId() -> Int {
        requestId += 1
        return requestId
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]? = nil) {
        var msg: [String: Any] = ["id": id, "method": method]
        if let params { msg["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        ws?.send(text)
    }

    private func sendResponse(id: Int, result: [String: Any]) {
        let msg: [String: Any] = ["id": id, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let text = String(data: data, encoding: .utf8) else { return }
        ws?.send(text)
    }

    func requestThreadList() {
        let rid = nextId()
        pendingRequests[rid] = "thread/list"
        var params: [String: Any] = ["limit": 50]
        if showArchivedThreads { params["showArchived"] = true }
        sendRequest(id: rid, method: "thread/list", params: params)
    }

    func requestLoadedThreads() {
        let rid = nextId()
        pendingRequests[rid] = "thread/loaded/list"
        sendRequest(id: rid, method: "thread/loaded/list", params: [:])
    }

    func archiveThread(_ threadId: String) {
        let rid = nextId()
        pendingRequests[rid] = "thread/archive"
        sendRequest(id: rid, method: "thread/archive", params: ["threadId": threadId])
    }

    func interruptThread(_ threadId: String) {
        let rid = nextId()
        pendingRequests[rid] = "turn/interrupt"
        sendRequest(id: rid, method: "turn/interrupt", params: ["threadId": threadId])
    }

    // MARK: - Thread lifecycle (v0.3.0)

    func createNewThread() {
        let rid = nextId()
        pendingRequests[rid] = "thread/start"
        sendRequest(id: rid, method: "thread/start", params: [:])
    }

    func unarchiveThread(_ threadId: String) {
        let rid = nextId()
        pendingRequests[rid] = "thread/unarchive"
        sendRequest(id: rid, method: "thread/unarchive", params: ["threadId": threadId])
    }

    func renameThread(_ threadId: String, name: String) {
        let rid = nextId()
        pendingRequests[rid] = "thread/name/set"
        sendRequest(id: rid, method: "thread/name/set", params: ["threadId": threadId, "name": name])
    }

    // MARK: - Account & rate limits (v0.3.0)

    func requestAccountInfo() {
        let rid = nextId()
        pendingRequests[rid] = "account/read"
        sendRequest(id: rid, method: "account/read", params: [:])
    }

    func requestRateLimits() {
        let rid = nextId()
        pendingRequests[rid] = "account/rateLimits/read"
        sendRequest(id: rid, method: "account/rateLimits/read", params: [:])
    }

    // MARK: - Reconnect / refresh

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Message routing

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let method = json["method"] as? String {
            if let id = json["id"] as? Int {
                // Server-to-client request (has both method and id)
                handleServerRequest(id: id, method: method, params: json["params"])
            } else {
                // Notification (method only)
                handleNotification(method: method, params: json["params"])
            }
        } else if let id = json["id"] as? Int {
            // Response to our request
            if json["error"] != nil {
                handleErrorResponse(id: id, error: json["error"] as? [String: Any] ?? [:])
            } else {
                handleResponse(id: id, result: json["result"])
            }
        }
    }

    // MARK: - Server requests (approvals)

    private func handleServerRequest(id: Int, method: String, params: Any?) {
        switch method {
        case "commandExecution/requestApproval":
            sendResponse(id: id, result: ["decision": "accept"])
            addEvent(method, summary: "Auto-approved command")

        case "fileChange/requestApproval":
            sendResponse(id: id, result: ["decision": "accept"])
            addEvent(method, summary: "Auto-approved file change")

        case "tool/requestUserInput":
            sendResponse(id: id, result: ["input": ""])
            addEvent(method, summary: "Auto-skipped user input request")

        default:
            sendResponse(id: id, result: [:])
        }
    }

    // MARK: - Responses

    private func handleResponse(id: Int, result: Any?) {
        let method = pendingRequests.removeValue(forKey: id)

        switch method {
        case "initialize":
            isConnected = true
            isConnecting = false
            addEvent("initialize", summary: "Connected to Codex server")
            requestThreadList()
            requestLoadedThreads()
            requestAccountInfo()
            requestRateLimits()
            startRefreshTimer()

        case "thread/list":
            if let dict = result as? [String: Any],
               let items = dict["data"] as? [[String: Any]] {
                threads = items.compactMap(parseThread)
                // Sync fairy previews
                let currentIds = Set(threads.filter { !$0.archived }.map(\.id))
                for thread in threads where !thread.archived {
                    if var preview = fairyPreviews[thread.id] {
                        preview.threadName = thread.name
                        preview.tokenUsage = thread.tokenUsage
                        fairyPreviews[thread.id] = preview
                    } else {
                        let identity = FairyIdentityGenerator.identity(for: thread.id)
                        fairyPreviews[thread.id] = FairyPreview(
                            id: thread.id, identity: identity, state: .idle,
                            previewText: "", threadName: thread.name,
                            tokenUsage: thread.tokenUsage,
                            lastActivity: thread.createdAt ?? Date(),
                            isSummoned: false, model: nil
                        )
                    }
                }
                // Remove previews for threads that no longer exist
                for key in fairyPreviews.keys where !currentIds.contains(key) {
                    fairyPreviews.removeValue(forKey: key)
                }
            }

        case "thread/loaded/list":
            if let dict = result as? [String: Any],
               let items = dict["data"] as? [[String: Any]] {
                loadedThreadIds = Set(items.compactMap { $0["id"] as? String })
            } else if let dict = result as? [String: Any],
                      let ids = dict["data"] as? [String] {
                loadedThreadIds = Set(ids)
            }

        case "thread/archive":
            addEvent("thread/archive", summary: "Thread archived")
            requestThreadList()

        case "thread/resume":
            isLoadingDetail = false
            if let dict = result as? [String: Any],
               let threadDict = dict["thread"] as? [String: Any] {
                detailModel = dict["modelProvider"] as? String ?? detailModel
                if let name = threadDict["name"] as? String { detailThreadName = name }
                if let turns = threadDict["turns"] as? [[String: Any]] {
                    detailItems = turns.flatMap(parseTurnItems)
                }
            }
            addEvent("thread/resume", summary: "Thread loaded")
            requestLoadedThreads()

        case "turn/start":
            addEvent("turn/start", summary: "Prompt sent")

        case "turn/interrupt":
            isTurnActive = false
            addEvent("turn/interrupt", summary: "Turn interrupted")

        case "thread/start":
            if let dict = result as? [String: Any],
               let threadDict = dict["thread"] as? [String: Any],
               let thread = parseThread(threadDict) {
                addEvent("thread/start", summary: "Created: \(thread.name)")
                requestThreadList()
                requestLoadedThreads()

                if let prompt = pendingSummonPrompt {
                    // Summon flow: create fairy, rename, send prompt
                    pendingSummonPrompt = nil
                    isSummoning = false
                    let identity = FairyIdentityGenerator.identity(for: thread.id)
                    fairyPreviews[thread.id] = FairyPreview(
                        id: thread.id, identity: identity, state: .thinking,
                        previewText: "", threadName: identity.name,
                        tokenUsage: nil, lastActivity: Date(), isSummoned: true,
                        model: "gpt-5.3-codex-spark"
                    )
                    renameThread(thread.id, name: identity.name)
                    let rid2 = nextId()
                    pendingRequests[rid2] = "turn/start"
                    sendRequest(id: rid2, method: "turn/start", params: [
                        "threadId": thread.id,
                        "effort": "low",
                        "input": [
                            ["type": "text", "text": prompt, "textElements": [Any]()] as [String: Any]
                        ],
                    ])
                } else {
                    selectThread(thread)
                }
            }

        case "thread/unarchive":
            addEvent("thread/unarchive", summary: "Thread unarchived")
            requestThreadList()

        case "thread/name/set":
            addEvent("thread/name/set", summary: "Thread renamed")

        case "account/read":
            if let dict = result as? [String: Any],
               let account = dict["account"] as? [String: Any] {
                accountEmail = account["email"] as? String
                accountPlan = account["planType"] as? String
            }

        case "account/rateLimits/read":
            if let dict = result as? [String: Any],
               let rl = dict["rateLimits"] as? [String: Any] {
                parseRateLimits(rl)
            }

        default:
            break
        }
    }

    private func handleErrorResponse(id: Int, error: [String: Any]) {
        let method = pendingRequests.removeValue(forKey: id)
        let message = error["message"] as? String ?? "Unknown error"
        lastError = "\(method ?? "?"): \(message)"
        if method == "initialize" { isConnecting = false }
        if method == "thread/resume" { isLoadingDetail = false }
        if method == "turn/start" { isTurnActive = false }
    }

    // MARK: - Notifications

    private func handleNotification(method: String, params: Any?) {
        let p = params as? [String: Any] ?? [:]
        let notifThreadId = p["threadId"] as? String

        switch method {
        case "thread/started":
            addEvent(method, summary: "New thread created")
            requestThreadList()

        case "thread/archived", "thread/unarchived":
            if method == "thread/archived", let tid = notifThreadId {
                fairyPreviews.removeValue(forKey: tid)
            }
            addEvent(method, summary: method == "thread/archived" ? "Thread archived" : "Thread unarchived")
            requestThreadList()

        case "thread/status/changed":
            let threadId = notifThreadId ?? "?"
            if let statusDict = p["status"] as? [String: Any],
               let statusType = statusDict["type"] as? String {
                addEvent(method, summary: "\(shortId(threadId)): \(statusType)")
                if let idx = threads.firstIndex(where: { $0.id == threadId }) {
                    threads[idx].status = statusType
                }
                if notifThreadId != nil {
                    let fairyState: FairyState = switch statusType {
                    case "thinking": .thinking
                    case "working", "running": .working
                    case "waiting": .waiting
                    case "error": .error
                    case "idle", "stopped": .idle
                    default: .idle
                    }
                    updateFairyState(threadId, fairyState)
                }
            }

        case "thread/name/updated":
            if let name = p["threadName"] as? String {
                if notifThreadId == selectedThreadId { detailThreadName = name }
                if let idx = threads.firstIndex(where: { $0.id == notifThreadId }) {
                    threads[idx].name = name
                }
                if let tid = notifThreadId {
                    fairyPreviews[tid]?.threadName = name
                }
            }

        case "turn/started":
            activeThreadId = notifThreadId
            hasActiveTurn = true
            if notifThreadId == selectedThreadId { isTurnActive = true }
            if let tid = notifThreadId { updateFairyState(tid, .thinking) }
            addEvent(method, summary: "Turn started")

        case "turn/completed":
            hasActiveTurn = false
            activeThreadId = nil
            if notifThreadId == selectedThreadId {
                isTurnActive = false
                streamingItemId = nil
            }
            if let tid = notifThreadId {
                updateFairyState(tid, .done)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    if self?.fairyPreviews[tid]?.state == .done {
                        self?.fairyPreviews[tid]?.state = .idle
                    }
                }
            }
            addEvent(method, summary: "Turn completed")

        case "item/started":
            guard notifThreadId == selectedThreadId,
                  let item = p["item"] as? [String: Any],
                  let turnId = p["turnId"] as? String else { break }
            if let parsed = parseItem(item, turnId: turnId) {
                streamingItemId = parsed.id
                detailItems.append(parsed)
            }

        case "item/completed":
            guard notifThreadId == selectedThreadId,
                  let item = p["item"] as? [String: Any],
                  let itemId = item["id"] as? String else { break }
            if let idx = detailItems.firstIndex(where: { $0.id == itemId }) {
                if let turnId = p["turnId"] as? String,
                   let updated = parseItem(item, turnId: turnId) {
                    detailItems[idx] = updated
                }
            }
            if itemId == streamingItemId { streamingItemId = nil }

        case "item/agentMessage/delta":
            if let tid = notifThreadId, let delta = p["delta"] as? String {
                appendFairyPreview(tid, delta: delta)
            }
            guard notifThreadId == selectedThreadId,
                  let itemId = p["itemId"] as? String,
                  let delta = p["delta"] as? String else { break }
            if let idx = detailItems.firstIndex(where: { $0.id == itemId }) {
                detailItems[idx].text += delta
            }

        case "item/commandExecution/outputDelta":
            if let tid = notifThreadId, let delta = p["delta"] as? String {
                appendFairyPreview(tid, delta: delta)
            }
            guard notifThreadId == selectedThreadId,
                  let itemId = p["itemId"] as? String,
                  let delta = p["delta"] as? String else { break }
            if let idx = detailItems.firstIndex(where: { $0.id == itemId }) {
                detailItems[idx].text += delta
            }

        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            if let tid = notifThreadId { updateFairyState(tid, .waiting) }
            let cmd = (p["command"] as? [String: Any])?["command"] as? String
            addEvent(method, summary: "Approval: \(truncStr(cmd ?? "file change", 40))")

        case "thread/tokenUsage/updated":
            if let usage = p["tokenUsage"] as? [String: Any],
               let total = usage["total"] as? [String: Any],
               let totalTokens = total["totalTokens"] as? Int {
                if notifThreadId == selectedThreadId { detailTokens = totalTokens }
                if let idx = threads.firstIndex(where: { $0.id == notifThreadId }) {
                    threads[idx].tokenUsage = totalTokens
                }
                if let tid = notifThreadId {
                    fairyPreviews[tid]?.tokenUsage = totalTokens
                }
            }

        case "error":
            let msg = (p["error"] as? [String: Any])?["message"] as? String ?? p["message"] as? String ?? "Unknown"
            addEvent(method, summary: msg)

        case "account/rateLimits/updated":
            if let rl = p["rateLimits"] as? [String: Any] {
                parseRateLimits(rl)
            }

        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta",
             "item/fileChange/outputDelta", "item/plan/delta":
            break

        default:
            addEvent(method, summary: method)
        }
    }

    // MARK: - Parsing

    private func parseThread(_ dict: [String: Any]) -> CodexThread? {
        guard let id = dict["id"] as? String else { return nil }
        let cwd = dict["cwd"] as? String
        let cwdName = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let name = dict["name"] as? String ?? cwdName ?? "Unnamed Thread"
        var createdAt: Date?
        if let ts = dict["createdAt"] as? Int {
            createdAt = Date(timeIntervalSince1970: TimeInterval(ts))
        } else if let ts = dict["createdAt"] as? Double {
            createdAt = Date(timeIntervalSince1970: ts)
        }
        return CodexThread(
            id: id, name: name, status: "idle",
            archived: dict["archived"] as? Bool ?? false,
            modelProvider: dict["modelProvider"] as? String,
            cwd: cwd, createdAt: createdAt
        )
    }

    private func parseTurnItems(_ turnDict: [String: Any]) -> [DisplayItem] {
        let turnId = turnDict["id"] as? String ?? UUID().uuidString
        guard let items = turnDict["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { parseItem($0, turnId: turnId) }
    }

    private func parseItem(_ dict: [String: Any], turnId: String) -> DisplayItem? {
        guard let id = dict["id"] as? String,
              let type = dict["type"] as? String else { return nil }

        var text = ""
        var status: String?
        var command: String?
        var files: [String]?
        var exitCode: Int?

        switch type {
        case "userMessage":
            if let content = dict["content"] as? [[String: Any]] {
                text = content.compactMap { c -> String? in
                    if c["type"] as? String == "text" { return c["text"] as? String }
                    if c["type"] as? String == "mention" { return "@\(c["name"] as? String ?? "file")" }
                    return nil
                }.joined(separator: " ")
            }
        case "agentMessage":
            text = dict["text"] as? String ?? ""
        case "commandExecution":
            command = dict["command"] as? String
            text = command ?? ""
            status = dict["status"] as? String
            exitCode = dict["exitCode"] as? Int
            if let output = dict["aggregatedOutput"] as? String, !output.isEmpty {
                text = (command ?? "") + "\n" + output
            }
        case "fileChange":
            if let changes = dict["changes"] as? [[String: Any]] {
                files = changes.compactMap { $0["path"] as? String }
                text = files?.joined(separator: ", ") ?? ""
            }
            status = dict["status"] as? String
        case "reasoning":
            let summaries = dict["summary"] as? [String] ?? []
            text = summaries.joined(separator: " ")
        case "plan":
            text = dict["text"] as? String ?? ""
        case "mcpToolCall":
            let server = dict["server"] as? String ?? ""
            let tool = dict["tool"] as? String ?? ""
            text = "\(server)/\(tool)"
            status = dict["status"] as? String
        case "contextCompaction":
            text = "Context compacted"
        default:
            text = type
        }

        return DisplayItem(id: id, turnId: turnId, type: type, text: text,
                           status: status, command: command, files: files, exitCode: exitCode)
    }

    private func addEvent(_ method: String, summary: String) {
        events.insert(ServerEvent(timestamp: Date(), method: method, summary: summary), at: 0)
        if events.count > 100 { events = Array(events.prefix(100)) }
    }

    private func shortId(_ s: String) -> String { String(s.prefix(8)) }

    private func truncStr(_ s: String, _ maxLen: Int) -> String {
        s.count > maxLen ? String(s.prefix(maxLen)) + "…" : s
    }

    private func parseRateLimits(_ rl: [String: Any]) {
        if let primary = rl["primary"] as? [String: Any] {
            rateLimitUsedPercent = primary["usedPercent"] as? Int
            if let ts = primary["resetsAt"] as? Int {
                rateLimitResetsAt = Date(timeIntervalSince1970: TimeInterval(ts))
            } else if let ts = primary["resetsAt"] as? Double {
                rateLimitResetsAt = Date(timeIntervalSince1970: ts)
            }
        }
        if let planType = rl["planType"] as? String {
            accountPlan = planType
        }
    }
}

// MARK: - Slack Layout Root

struct SlackLayoutView: View {
    @Bindable var connection: CodexConnection
    let isPopout: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(connection: connection, isPopout: isPopout, openWindow: openWindow)
                .frame(width: SlackTheme.sidebarWidth)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            ContentAreaView(connection: connection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            width: isPopout ? SlackTheme.popoutWidth : SlackTheme.menuBarWidth,
            height: isPopout ? SlackTheme.popoutHeight : SlackTheme.menuBarHeight
        )
        .background(SlackTheme.contentBG)
        .background {
            // Cmd+N: new thread
            Button { connection.createNewThread() } label: { EmptyView() }
                .keyboardShortcut("n", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0)

            // Cmd+W: deselect thread
            Button { connection.deselectThread() } label: { EmptyView() }
                .keyboardShortcut("w", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0)

            // Escape: cancel name editing or dismiss summon input
            Button {
                if connection.isEditingName {
                    connection.isEditingName = false
                } else if connection.showSummonInput {
                    connection.showSummonInput = false
                    connection.summonText = ""
                }
            } label: { EmptyView() }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0).opacity(0)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Bindable var connection: CodexConnection
    let isPopout: Bool
    let openWindow: OpenWindowAction

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider().background(Color.white.opacity(0.1))
            ScrollView {
                VStack(spacing: 2) {
                    if connection.isConnected {
                        threadsSidebarSection
                        fairiesSidebarSection
                        eventsSidebarRow
                    } else {
                        disconnectedSection
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
            Divider().background(Color.white.opacity(0.1))
            sidebarFooter
        }
        .background(SlackTheme.sidebarBG)
    }

    // MARK: Header

    private var sidebarHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("CodexPilot")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(SlackTheme.sidebarText)
                        Circle()
                            .fill(connection.isConnected ? SlackTheme.presenceGreen : .red.opacity(0.7))
                            .frame(width: 8, height: 8)
                    }
                    if !connection.isConnected {
                        Text(connection.isConnecting ? "Connecting..." : connection.serverAddress)
                            .font(.system(size: 10))
                            .foregroundStyle(SlackTheme.sidebarMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if !isPopout {
                    Button {
                        openWindow(id: "codexpilot-popout")
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11))
                            .foregroundStyle(SlackTheme.sidebarMuted)
                    }
                    .buttonStyle(.borderless)
                    .help("Open in window")
                }
            }
            if !connection.isConnected {
                Button {
                    connection.connect()
                } label: {
                    Text("Connect")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(SlackTheme.presenceGreen, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.borderless)
                .disabled(connection.isConnecting)
            }
            if let error = connection.lastError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Threads Section

    private var threadsSidebarSection: some View {
        VStack(spacing: 0) {
            // Section header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { connection.threadsCollapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: connection.threadsCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(SlackTheme.sidebarMuted)
                        .frame(width: 12)
                    Text("THREADS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SlackTheme.sidebarMuted)
                    if !connection.threads.isEmpty {
                        Text("\(connection.threads.count)")
                            .font(.system(size: 9))
                            .foregroundStyle(SlackTheme.sidebarMuted.opacity(0.6))
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                HStack(spacing: 2) {
                    Button {
                        connection.showArchivedThreads.toggle()
                        connection.requestThreadList()
                    } label: {
                        Image(systemName: connection.showArchivedThreads ? "archivebox.fill" : "archivebox")
                            .font(.system(size: 10))
                            .foregroundStyle(connection.showArchivedThreads ? .orange : SlackTheme.sidebarMuted)
                    }
                    .buttonStyle(.borderless)
                    Button { connection.createNewThread() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SlackTheme.sidebarMuted)
                    }
                    .buttonStyle(.borderless)
                    .help("New thread")
                }
                .padding(.trailing, 14)
            }

            if !connection.threadsCollapsed {
                if connection.threads.isEmpty {
                    Text("No threads")
                        .font(.system(size: 11))
                        .foregroundStyle(SlackTheme.sidebarMuted.opacity(0.5))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                } else {
                    ForEach(connection.threads) { thread in
                        SidebarChannelRow(
                            name: thread.name,
                            isSelected: connection.selectedThreadId == thread.id,
                            isActive: connection.activeThreadId == thread.id,
                            isArchived: thread.archived
                        ) {
                            connection.selectThread(thread)
                        }
                    }
                }
            }
        }
    }

    // MARK: Fairies Section

    private var fairiesSidebarSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { connection.fairiesCollapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: connection.fairiesCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(SlackTheme.sidebarMuted)
                        .frame(width: 12)
                    Text("FAIRIES")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SlackTheme.sidebarMuted)
                    if !connection.sortedFairies.isEmpty {
                        Text("\(connection.sortedFairies.count)")
                            .font(.system(size: 9))
                            .foregroundStyle(SlackTheme.sidebarMuted.opacity(0.6))
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                HStack(spacing: 2) {
                    Button {
                        connection.contentMode = .fairyGarden
                        connection.selectedThreadId = nil
                    } label: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(SlackTheme.sidebarMuted)
                    }
                    .buttonStyle(.borderless)
                    .help("Fairy garden")
                    Button {
                        withAnimation { connection.showSummonInput.toggle() }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SlackTheme.sidebarMuted)
                    }
                    .buttonStyle(.borderless)
                    .help("Summon fairy")
                }
                .padding(.trailing, 14)
            }

            if connection.showSummonInput {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple)
                    TextField("Task for fairy...", text: $connection.summonText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(SlackTheme.sidebarText)
                        .onSubmit {
                            connection.summonFairy(prompt: connection.summonText)
                            connection.summonText = ""
                            connection.showSummonInput = false
                        }
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, 10).padding(.bottom, 4)
            }

            if !connection.fairiesCollapsed {
                ForEach(connection.sortedFairies) { fairy in
                    SidebarFairyRow(
                        fairy: fairy,
                        isSelected: connection.selectedThreadId == fairy.id
                    ) {
                        if let thread = connection.threads.first(where: { $0.id == fairy.id }) {
                            connection.selectThread(thread)
                        }
                    }
                }
            }
        }
    }

    // MARK: Events Row

    private var eventsSidebarRow: some View {
        SidebarChannelRow(
            name: "events",
            isSelected: connection.contentMode == .eventLog,
            isActive: false,
            isArchived: false
        ) {
            connection.contentMode = .eventLog
            connection.selectedThreadId = nil
        }
        .padding(.top, 4)
    }

    // MARK: Disconnected

    private var disconnectedSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.system(size: 20))
                .foregroundStyle(SlackTheme.sidebarMuted.opacity(0.4))
            Text("Start the server:")
                .font(.system(size: 10))
                .foregroundStyle(SlackTheme.sidebarMuted)
            Text("codex-app-server\n  --listen ws://127.0.0.1:8080")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SlackTheme.sidebarMuted.opacity(0.7))
                .padding(6)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 14).padding(.vertical, 20)
    }

    // MARK: Footer

    private var sidebarFooter: some View {
        VStack(spacing: 4) {
            if let pct = connection.rateLimitUsedPercent {
                HStack(spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.1))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(rateLimitColor(pct))
                                .frame(width: geo.size.width * CGFloat(min(pct, 100)) / 100.0)
                        }
                    }
                    .frame(height: 4)
                    Text("\(pct)%")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(rateLimitColor(pct))
                }
            }
            HStack(spacing: 4) {
                if let plan = connection.accountPlan {
                    Text(plan.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(planColor(plan))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(planColor(plan).opacity(0.2), in: Capsule())
                }
                if let email = connection.accountEmail {
                    Text(email)
                        .font(.system(size: 9))
                        .foregroundStyle(SlackTheme.sidebarMuted)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 10))
                        .foregroundStyle(SlackTheme.sidebarMuted)
                }
                .buttonStyle(.borderless)
                .help("Quit")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func rateLimitColor(_ pct: Int) -> Color {
        if pct >= 80 { return .red }
        if pct >= 50 { return .orange }
        return SlackTheme.presenceGreen
    }

    private func planColor(_ plan: String) -> Color {
        switch plan.lowercased() {
        case "pro": return .purple
        case "plus": return .blue
        case "team": return .cyan
        case "enterprise", "business": return .indigo
        default: return .gray
        }
    }
}

// MARK: - Sidebar Channel Row

struct SidebarChannelRow: View {
    let name: String
    let isSelected: Bool
    let isActive: Bool
    let isArchived: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button { onTap() } label: {
            HStack(spacing: 6) {
                Text("#")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? .white : SlackTheme.sidebarMuted)
                Text(name)
                    .font(.system(size: 13, weight: isActive ? .bold : .regular))
                    .foregroundStyle(isSelected ? .white : (isArchived ? SlackTheme.sidebarMuted.opacity(0.5) : SlackTheme.sidebarText.opacity(0.85)))
                    .lineLimit(1)
                Spacer()
                if isActive {
                    Circle()
                        .fill(SlackTheme.mentionBadge)
                        .frame(width: 8, height: 8)
                }
                if isArchived {
                    Image(systemName: "archivebox")
                        .font(.system(size: 8))
                        .foregroundStyle(SlackTheme.sidebarMuted.opacity(0.4))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(
                isSelected ? SlackTheme.sidebarActive :
                    (hovered ? SlackTheme.sidebarHover : Color.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Sidebar Fairy Row

struct SidebarFairyRow: View {
    let fairy: FairyPreview
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovered = false

    private var isActive: Bool {
        fairy.state == .working || fairy.state == .thinking || fairy.state == .waiting
    }

    private var subtitleText: String? {
        guard isActive, !fairy.previewText.isEmpty else { return nil }
        let cleaned = fairy.previewText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : String(cleaned.suffix(50))
    }

    var body: some View {
        Button { onTap() } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(presenceColor)
                    .frame(width: 8, height: 8)
                Image(systemName: fairy.identity.emoji)
                    .font(.system(size: 11))
                    .foregroundStyle(fairy.identity.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(fairy.identity.name)
                        .font(.system(size: 13, weight: isActive ? .bold : .regular))
                        .foregroundStyle(isSelected ? .white : SlackTheme.sidebarText.opacity(0.85))
                        .lineLimit(1)
                    if let subtitle = subtitleText {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(SlackTheme.sidebarMuted.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isActive {
                    ProgressView()
                        .scaleEffect(0.35)
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(
                isSelected ? SlackTheme.sidebarActive :
                    (hovered ? SlackTheme.sidebarHover : Color.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var presenceColor: Color {
        switch fairy.state {
        case .working, .thinking: return .orange
        case .waiting: return .yellow
        case .done: return SlackTheme.presenceGreen
        case .error: return .red
        case .idle: return SlackTheme.presenceGreen.opacity(0.5)
        case .sleeping: return .gray
        }
    }
}

// MARK: - Content Area Router

struct ContentAreaView: View {
    @Bindable var connection: CodexConnection

    var body: some View {
        Group {
            switch connection.contentMode {
            case .empty:
                EmptyContentView(connection: connection)
            case .threadDetail:
                ThreadDetailContent(connection: connection)
            case .fairyGarden:
                FairyGardenContent(connection: connection)
            case .eventLog:
                EventLogContent(connection: connection)
            }
        }
        .background(SlackTheme.contentBG)
    }
}

// MARK: - Empty Content

struct EmptyContentView: View {
    @Bindable var connection: CodexConnection

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 40))
                .foregroundStyle(SlackTheme.contentText.opacity(0.2))
            Text("Select a thread to get started")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SlackTheme.contentText.opacity(0.5))
            if !connection.isConnected {
                Text("Connect to a Codex server first")
                    .font(.system(size: 12))
                    .foregroundStyle(SlackTheme.contentText.opacity(0.3))
            } else {
                Text("\(connection.threads.count) threads available")
                    .font(.system(size: 12))
                    .foregroundStyle(SlackTheme.contentText.opacity(0.3))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Thread Detail Content

struct ThreadDetailContent: View {
    @Bindable var connection: CodexConnection

    var body: some View {
        VStack(spacing: 0) {
            contentHeader
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            messageList
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            composer
        }
    }

    // MARK: Content Header

    private var contentHeader: some View {
        HStack(spacing: 8) {
            Text("#")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(SlackTheme.contentText.opacity(0.5))

            if connection.isEditingName {
                TextField("Thread name", text: $connection.editingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SlackTheme.brightText)
                    .frame(maxWidth: 200)
                    .onSubmit {
                        if let tid = connection.selectedThreadId, !connection.editingName.isEmpty {
                            connection.renameThread(tid, name: connection.editingName)
                            connection.detailThreadName = connection.editingName
                        }
                        connection.isEditingName = false
                    }
            } else {
                Text(connection.detailThreadName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SlackTheme.brightText)
                    .lineLimit(1)
                    .onTapGesture {
                        connection.editingName = connection.detailThreadName
                        connection.isEditingName = true
                    }
                    .help("Click to rename")
            }

            if let model = connection.detailModel {
                Text("|")
                    .font(.system(size: 12))
                    .foregroundStyle(SlackTheme.contentText.opacity(0.2))
                Text(model)
                    .font(.system(size: 11))
                    .foregroundStyle(SlackTheme.contentText.opacity(0.5))
            }
            if let tokens = connection.detailTokens {
                Text(formatTokens(tokens))
                    .font(.system(size: 11))
                    .foregroundStyle(SlackTheme.contentText.opacity(0.4))
            }

            Spacer()

            if connection.isTurnActive {
                HStack(spacing: 4) {
                    ProgressView().scaleEffect(0.4)
                    Text("active")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                if let tid = connection.selectedThreadId {
                    Button {
                        connection.interruptThread(tid)
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.borderless)
                    .help("Interrupt")
                }
            }

            if let tid = connection.selectedThreadId {
                Button {
                    connection.archiveThread(tid)
                    connection.deselectThread()
                } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: 12))
                        .foregroundStyle(SlackTheme.contentText.opacity(0.4))
                }
                .buttonStyle(.borderless)
                .help("Archive thread")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(height: SlackTheme.headerHeight)
    }

    // MARK: Message List

    @State private var isNearBottom = true
    @State private var showJumpButton = false

    private var displayRows: [DisplayRow] {
        var rows: [DisplayRow] = []
        var turnNumber = 0
        var lastTurnId: String?
        var lastType: String?

        for item in connection.detailItems {
            if item.turnId != lastTurnId {
                turnNumber += 1
                rows.append(.divider(turnNumber: turnNumber, turnId: item.turnId))
                lastType = nil
            }
            let sameGroupAsPrev = (item.turnId == lastTurnId && item.type == lastType)
            rows.append(.message(
                item: item,
                showAvatar: !sameGroupAsPrev,
                isStreaming: item.id == connection.streamingItemId
            ))
            lastTurnId = item.turnId
            lastType = item.type
        }
        return rows
    }

    private var messageList: some View {
        Group {
            if connection.isLoadingDetail {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(SlackTheme.contentText.opacity(0.5))
                    Text("Loading thread...")
                        .font(.system(size: 13))
                        .foregroundStyle(SlackTheme.contentText.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if connection.detailItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 28))
                        .foregroundStyle(SlackTheme.contentText.opacity(0.15))
                    Text("This is the very beginning of #\(connection.detailThreadName)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SlackTheme.contentText.opacity(0.4))
                    Text("Send a prompt below to start a conversation")
                        .font(.system(size: 12))
                        .foregroundStyle(SlackTheme.contentText.opacity(0.25))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(displayRows) { row in
                                switch row {
                                case .divider(let num, _):
                                    TurnDivider(turnNumber: num)
                                case .message(let item, let showAvatar, let streaming):
                                    SlackMessageRow(
                                        item: item,
                                        isStreaming: streaming,
                                        showAvatar: showAvatar
                                    )
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("__bottom__")
                                .onAppear { isNearBottom = true; showJumpButton = false }
                                .onDisappear { isNearBottom = false }
                        }
                        .padding(.vertical, 8)
                    }
                    .overlay(alignment: .bottom) {
                        if showJumpButton {
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("__bottom__", anchor: .bottom)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("New messages")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(SlackTheme.linkBlue, in: Capsule())
                                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .onChange(of: connection.detailItems.count) {
                        if isNearBottom {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("__bottom__", anchor: .bottom)
                            }
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showJumpButton = true
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message #\(connection.detailThreadName)...", text: $connection.promptText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(SlackTheme.brightText)
                .disabled(connection.isTurnActive)
                .onSubmit { connection.sendPrompt() }

            Button {
                if connection.isTurnActive, let tid = connection.selectedThreadId {
                    connection.interruptThread(tid)
                } else {
                    connection.sendPrompt()
                }
            } label: {
                Image(systemName: connection.isTurnActive ? "stop.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(connection.isTurnActive ? .red : SlackTheme.linkBlue)
            }
            .buttonStyle(.borderless)
            .disabled(!connection.isTurnActive && connection.promptText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(SlackTheme.composerBorder, lineWidth: 1)
                .background(SlackTheme.composerBG, in: RoundedRectangle(cornerRadius: 8))
        )
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func formatTokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk tok", Double(n) / 1000.0) : "\(n) tok"
    }
}

// MARK: - Turn Divider

struct TurnDivider: View {
    let turnNumber: Int

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(SlackTheme.contentText.opacity(0.1))
                .frame(height: 1)
            Text("Turn \(turnNumber)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SlackTheme.contentText.opacity(0.35))
                .fixedSize()
            Rectangle()
                .fill(SlackTheme.contentText.opacity(0.1))
                .frame(height: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - Display Row (for turn dividers + message grouping)

enum DisplayRow: Identifiable {
    case divider(turnNumber: Int, turnId: String)
    case message(item: DisplayItem, showAvatar: Bool, isStreaming: Bool)

    var id: String {
        switch self {
        case .divider(_, let turnId): return "divider-\(turnId)"
        case .message(let item, _, _): return item.id
        }
    }
}

// MARK: - Slack Message Row

struct SlackMessageRow: View {
    let item: DisplayItem
    let isStreaming: Bool
    let showAvatar: Bool
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showAvatar {
                // Avatar
                RoundedRectangle(cornerRadius: 4)
                    .fill(avatarColor.opacity(0.15))
                    .frame(width: SlackTheme.avatarSize, height: SlackTheme.avatarSize)
                    .overlay {
                        Image(systemName: avatarIcon)
                            .font(.system(size: 16))
                            .foregroundStyle(avatarColor)
                    }
            } else {
                Spacer()
                    .frame(width: SlackTheme.avatarSize)
            }

            VStack(alignment: .leading, spacing: 2) {
                if showAvatar {
                    // Sender + timestamp
                    HStack(spacing: 6) {
                        Text(senderName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(SlackTheme.brightText)
                        Text(item.turnId.prefix(8))
                            .font(.system(size: 10))
                            .foregroundStyle(SlackTheme.contentText.opacity(0.35))
                        if isStreaming {
                            ProgressView()
                                .scaleEffect(0.35)
                                .frame(width: 12, height: 12)
                        }
                    }
                } else if isStreaming {
                    ProgressView()
                        .scaleEffect(0.35)
                        .frame(width: 12, height: 12)
                }

                // Message text
                if item.type == "commandExecution" {
                    commandBlock
                } else if item.type == "fileChange" {
                    fileChangeBlock
                } else {
                    Text(item.text.isEmpty ? "..." : item.text)
                        .font(.system(size: 14))
                        .foregroundStyle(SlackTheme.contentText)
                        .textSelection(.enabled)
                        .lineLimit(item.type == "agentMessage" ? 20 : 6)
                }

                // Status badge
                if let status = item.status {
                    HStack(spacing: 4) {
                        if let code = item.exitCode {
                            Text("exit \(code)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(code == 0 ? SlackTheme.presenceGreen : .red)
                        }
                        Text(status)
                            .font(.system(size: 10))
                            .foregroundStyle(statusColor(status))
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(hovered ? SlackTheme.contentHover : .clear)
        .onHover { hovered = $0 }
        .id(item.id)
    }

    // Command block (monospace)
    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cmd = item.command {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 9))
                        .foregroundStyle(SlackTheme.contentText.opacity(0.4))
                    Text(cmd)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(SlackTheme.contentText.opacity(0.9))
                        .lineLimit(1)
                }
            }
            let output = item.command.map { item.text.replacingOccurrences(of: $0, with: "").trimmingCharacters(in: .whitespacesAndNewlines) } ?? item.text
            if !output.isEmpty {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SlackTheme.contentText.opacity(0.6))
                    .lineLimit(8)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // File change block
    private var fileChangeBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let files = item.files {
                ForEach(files.prefix(5), id: \.self) { file in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(SlackTheme.linkBlue)
                        Text(URL(fileURLWithPath: file).lastPathComponent)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(SlackTheme.linkBlue)
                    }
                }
                if files.count > 5 {
                    Text("+\(files.count - 5) more")
                        .font(.system(size: 11))
                        .foregroundStyle(SlackTheme.contentText.opacity(0.4))
                }
            }
        }
    }

    private var senderName: String {
        switch item.type {
        case "userMessage": return "You"
        case "agentMessage": return "Codex"
        case "commandExecution": return "Terminal"
        case "fileChange": return "File System"
        case "reasoning": return "Reasoning"
        case "plan": return "Plan"
        case "mcpToolCall": return "MCP Tool"
        case "contextCompaction": return "System"
        default: return item.type
        }
    }

    private var avatarIcon: String {
        switch item.type {
        case "userMessage": return "person.fill"
        case "agentMessage": return "sparkles"
        case "commandExecution": return "terminal.fill"
        case "fileChange": return "doc.badge.plus"
        case "reasoning": return "brain"
        case "plan": return "list.clipboard"
        case "mcpToolCall": return "puzzlepiece.fill"
        case "contextCompaction": return "arrow.triangle.2.circlepath"
        default: return "circle.fill"
        }
    }

    private var avatarColor: Color {
        switch item.type {
        case "userMessage": return .blue
        case "agentMessage": return .purple
        case "commandExecution": return .orange
        case "fileChange": return .green
        case "reasoning": return .yellow
        case "plan": return .cyan
        case "mcpToolCall": return .pink
        default: return .gray
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": return SlackTheme.presenceGreen
        case "inProgress": return .orange
        case "failed", "declined": return .red
        default: return .gray
        }
    }
}

// MARK: - Fairy Garden Content

struct FairyGardenContent: View {
    @Bindable var connection: CodexConnection

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(.purple)
                Text("Fairy Garden")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SlackTheme.brightText)
                Spacer()
                let active = connection.activeFairyCount
                if active > 0 {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.35)
                        Text("\(active) active")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(connection.fairyPreviews.count) total")
                    .font(.system(size: 11))
                    .foregroundStyle(SlackTheme.contentText.opacity(0.4))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(height: SlackTheme.headerHeight)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // Canvas
            fairyCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            // Summon bar
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12))
                    .foregroundStyle(.purple)
                TextField("Summon a fairy...", text: $connection.summonText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(SlackTheme.brightText)
                    .disabled(connection.isSummoning)
                    .onSubmit {
                        connection.summonFairy(prompt: connection.summonText)
                        connection.summonText = ""
                    }
                Button {
                    connection.summonFairy(prompt: connection.summonText)
                    connection.summonText = ""
                } label: {
                    if connection.isSummoning {
                        ProgressView().scaleEffect(0.5)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.purple)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(connection.isSummoning || connection.summonText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SlackTheme.composerBorder, lineWidth: 1)
                    .background(SlackTheme.composerBG, in: RoundedRectangle(cornerRadius: 8))
            )
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var fairyCanvas: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hue: 0.75, saturation: 0.15, brightness: 0.08),
                        Color(hue: 0.55, saturation: 0.12, brightness: 0.05),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                ForEach(0..<12, id: \.self) { i in
                    Circle()
                        .fill(.white.opacity(Double.random(in: 0.05...0.15)))
                        .frame(width: CGFloat.random(in: 1.5...3), height: CGFloat.random(in: 1.5...3))
                        .position(starPosition(index: i, in: geo.size))
                }

                if connection.sortedFairies.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 32))
                            .foregroundStyle(.purple.opacity(0.35))
                        Text("Summon your first fairy")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("Type a task below and press return")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.2))
                    }
                } else {
                    ForEach(connection.sortedFairies) { fairy in
                        FairyOrb(fairy: fairy) {
                            if let thread = connection.threads.first(where: { $0.id == fairy.id }) {
                                connection.selectThread(thread)
                            }
                        }
                        .position(orbPosition(for: fairy, in: geo.size))
                    }
                }
            }
        }
    }

    private func orbPosition(for fairy: FairyPreview, in size: CGSize) -> CGPoint {
        var hash: UInt64 = 5381
        for byte in fairy.id.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let isActive = fairy.state == .working || fairy.state == .thinking || fairy.state == .waiting
        let margin: CGFloat = 40
        let rangeW = size.width - margin * 2
        let rangeH = size.height - margin * 2
        var x = margin + CGFloat(hash % 1000) / 1000.0 * rangeW
        var y = margin + CGFloat((hash / 997) % 1000) / 1000.0 * rangeH
        if isActive {
            let cx = size.width / 2, cy = size.height / 2
            x = cx + (x - cx) * 0.4
            y = cy + (y - cy) * 0.4
        }
        return CGPoint(x: x, y: y)
    }

    private func starPosition(index: Int, in size: CGSize) -> CGPoint {
        let seeds: [(Double, Double)] = [
            (0.12, 0.15), (0.85, 0.22), (0.35, 0.78), (0.72, 0.65),
            (0.08, 0.52), (0.92, 0.88), (0.48, 0.12), (0.65, 0.42),
            (0.22, 0.92), (0.78, 0.08), (0.55, 0.55), (0.38, 0.35),
        ]
        let s = seeds[index % seeds.count]
        return CGPoint(x: s.0 * size.width, y: s.1 * size.height)
    }
}

// MARK: - Event Log Content

struct EventLogContent: View {
    @Bindable var connection: CodexConnection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("#")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(SlackTheme.contentText.opacity(0.5))
                Text("events")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SlackTheme.brightText)
                Spacer()
                Text("\(connection.events.count) events")
                    .font(.system(size: 11))
                    .foregroundStyle(SlackTheme.contentText.opacity(0.4))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(height: SlackTheme.headerHeight)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            if connection.events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 28))
                        .foregroundStyle(SlackTheme.contentText.opacity(0.15))
                    Text("No events yet")
                        .font(.system(size: 13))
                        .foregroundStyle(SlackTheme.contentText.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(connection.events) { event in
                            EventRow(event: event)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Fairy Orb (spatial canvas node)

struct FairyOrb: View {
    let fairy: FairyPreview
    let onTap: () -> Void

    @State private var hovered = false
    @State private var pulseScale: CGFloat = 1.0

    private var isActive: Bool {
        fairy.state == .working || fairy.state == .thinking || fairy.state == .waiting
    }

    var body: some View {
        Button { onTap() } label: {
            VStack(spacing: 3) {
                // Main orb circle
                ZStack {
                    // State ring
                    Circle()
                        .stroke(stateDotColor.opacity(isActive ? 0.6 : 0.25), lineWidth: 2)
                        .frame(width: 46, height: 46)

                    // Fill
                    Circle()
                        .fill(fairy.identity.color.opacity(hovered ? 0.18 : 0.08))
                        .frame(width: 42, height: 42)

                    // Icon
                    Image(systemName: fairy.identity.emoji)
                        .font(.system(size: 18))
                        .foregroundStyle(fairy.identity.color)
                        .scaleEffect(pulseScale)
                }
                .shadow(color: isActive ? fairy.identity.color.opacity(0.5) : .clear, radius: isActive ? 8 : 0)

                // Name
                Text(fairy.identity.name)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)

                // Model label
                if let model = fairy.model {
                    Text(model.replacingOccurrences(of: "gpt-5.3-codex-", with: ""))
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 70, height: 80)
            .overlay(alignment: .topTrailing) {
                // Token badge
                if let tokens = fairy.tokenUsage, tokens > 0 {
                    Text(tokens >= 1000 ? String(format: "%.0fk", Double(tokens)/1000) : "\(tokens)")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(fairy.identity.color.opacity(0.7)))
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .popover(isPresented: .constant(hovered && !fairy.previewText.isEmpty)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Circle().fill(stateDotColor).frame(width: 6, height: 6)
                    Text(fairy.state.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(stateTextColor)
                }
                Text(cleanPreview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: 200, alignment: .leading)
            }
            .padding(8)
        }
        .onAppear {
            if isActive { startPulsing() }
        }
        .onChange(of: fairy.state) { _, newState in
            let nowActive = newState == .working || newState == .thinking || newState == .waiting
            if nowActive {
                startPulsing()
            } else if newState == .done {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { pulseScale = 1.2 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.4)) { pulseScale = 1.0 }
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { pulseScale = 1.0 }
            }
        }
    }

    private func startPulsing() {
        pulseScale = 1.0
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            pulseScale = 1.12
        }
    }

    private var cleanPreview: String {
        fairy.previewText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private var stateDotColor: Color {
        switch fairy.state {
        case .working, .thinking: return .orange
        case .waiting: return .yellow
        case .done: return .green
        case .error: return .red
        case .idle: return .secondary.opacity(0.5)
        case .sleeping: return .purple.opacity(0.4)
        }
    }

    private var stateTextColor: Color {
        switch fairy.state {
        case .working, .thinking: return .orange
        case .waiting: return .yellow
        case .done: return .green
        case .error: return .red
        default: return .secondary
        }
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: ServerEvent
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(event.summary)
                .font(.system(size: 12))
                .foregroundStyle(SlackTheme.contentText)
                .lineLimit(1)
            Spacer()
            Text(event.timestamp, style: .time)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SlackTheme.contentText.opacity(0.3))
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
        .background(hovered ? SlackTheme.contentHover : .clear)
        .onHover { hovered = $0 }
    }

    private var icon: String {
        let m = event.method
        if m.contains("turn/started") { return "play.fill" }
        if m.contains("turn/completed") { return "checkmark.circle.fill" }
        if m.contains("thread") { return "bubble.left.fill" }
        if m.contains("approval") { return "exclamationmark.triangle.fill" }
        if m.contains("error") { return "xmark.circle.fill" }
        if m.contains("initialize") { return "bolt.fill" }
        if m.contains("token") { return "number.circle" }
        return "circle.fill"
    }

    private var color: Color {
        let m = event.method
        if m.contains("error") { return .red }
        if m.contains("approval") { return .orange }
        if m.contains("started") { return .blue }
        if m.contains("completed") { return .green }
        if m.contains("initialize") { return .green }
        return .secondary
    }
}

// MARK: - App Entry

@main
struct CodexPilotApp: App {
    @State private var connection = CodexConnection()

    var body: some Scene {
        MenuBarExtra {
            SlackLayoutView(connection: connection, isPopout: false)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: menuBarIcon)
                if connection.activeFairyCount > 0 {
                    Text("\(connection.activeFairyCount)")
                } else if let pct = connection.rateLimitUsedPercent, connection.isConnected {
                    Text("\(pct)%")
                } else {
                    Text("Codex")
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("CodexPilot", id: "codexpilot-popout") {
            SlackLayoutView(connection: connection, isPopout: true)
                .frame(minWidth: 600, minHeight: 400)
        }
        .defaultSize(width: SlackTheme.popoutWidth, height: SlackTheme.popoutHeight)
    }

    private var menuBarIcon: String {
        if !connection.isConnected { return "circle.dotted" }
        if connection.activeFairyCount > 0 { return "wand.and.stars" }
        if connection.hasActiveTurn { return "bolt.fill" }
        if let pct = connection.rateLimitUsedPercent, pct >= 80 { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }
}
