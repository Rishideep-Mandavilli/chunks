import Foundation

/// The address and bearer token of the owner's own Nod server, reached over Tailscale.
///
/// This is not a cloud backend: it is a machine the owner runs, named by a tailnet address, and the
/// token is the dispatch key that server printed. Chunks sends a sentence and gets a task ID back;
/// the long-running work happens on Nod, not here.
public struct NodBridgeConfiguration: Equatable, Sendable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }
}

public struct NodTaskReceipt: Equatable, Sendable {
    public let taskId: String
    public let status: String

    public init(taskId: String, status: String) {
        self.taskId = taskId
        self.status = status
    }
}

public struct NodTaskStatus: Equatable, Sendable {
    public let taskId: String
    public let title: String
    public let status: String
    public let result: String
    public let updatedAt: String

    public init(taskId: String, title: String, status: String, result: String, updatedAt: String) {
        self.taskId = taskId
        self.title = title
        self.status = status
        self.result = result
        self.updatedAt = updatedAt
    }
}

public enum NodBridgeError: Error, Equatable {
    case notConfigured
    case badResponse(String)
    case transport(String)
}

/// Dispatches a natural-language task to Nod and reads its status back.
///
/// The request building and the response parsing are pure so they can be tested without a network;
/// only `dispatch` and `status` touch URLSession. A failure keeps Nod's own reason rather than a
/// generic warning, because "the token was refused" and "the server is asleep" are different things
/// for the owner to act on.
public enum NodTaskBridge {

    public static func dispatchRequest(
        configuration: NodBridgeConfiguration,
        instruction: String,
        title: String? = nil,
        callbackURL: String? = nil
    ) -> URLRequest {
        var request = URLRequest(
            url: configuration.baseURL.appendingPathComponent("api/v1/external/tasks/dispatch"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["instruction": instruction]
        if let title, !title.isEmpty { body["title"] = title }
        if let callbackURL, !callbackURL.isEmpty { body["callbackUrl"] = callbackURL }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func statusRequest(
        configuration: NodBridgeConfiguration,
        taskId: String
    ) -> URLRequest {
        // A task ID is opaque server-supplied text; keep it to a safe path segment so it cannot
        // climb out of the tasks collection (QA P4).
        let safe = taskId.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }.map(String.init).joined()
        var request = URLRequest(
            url: configuration.baseURL
                .appendingPathComponent("api/v1/external/tasks")
                .appendingPathComponent(String(safe.prefix(64))))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func parseReceipt(_ data: Data) throws -> NodTaskReceipt {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taskId = object["taskId"] as? String, !taskId.isEmpty
        else { throw NodBridgeError.badResponse("Nod did not return a task ID.") }
        // Remote strings are bounded before they can reach the card, the voice or the log (QA P2).
        return NodTaskReceipt(taskId: String(taskId.prefix(64)),
                              status: String(((object["status"] as? String) ?? "queued").prefix(32)))
    }

    public static func parseStatus(_ data: Data) throws -> NodTaskStatus {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taskId = object["taskId"] as? String, !taskId.isEmpty
        else { throw NodBridgeError.badResponse("Nod did not return that task.") }
        return NodTaskStatus(
            taskId: String(taskId.prefix(64)),
            title: String(((object["title"] as? String) ?? "").prefix(120)),
            status: String(((object["status"] as? String) ?? "queued").prefix(32)),
            result: String(((object["result"] as? String) ?? "").prefix(400)),
            updatedAt: String(((object["updatedAt"] as? String) ?? "").prefix(40)))
    }

    public static func dispatch(
        configuration: NodBridgeConfiguration,
        instruction: String,
        title: String? = nil,
        callbackURL: String? = nil
    ) async throws -> NodTaskReceipt {
        let request = dispatchRequest(
            configuration: configuration, instruction: instruction,
            title: title, callbackURL: callbackURL)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try parseReceipt(data)
    }

    public static func status(
        configuration: NodBridgeConfiguration,
        taskId: String
    ) async throws -> NodTaskStatus {
        let request = statusRequest(configuration: configuration, taskId: taskId)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try parseStatus(data)
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NodBridgeError.transport("Nod did not answer.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NodBridgeError.badResponse(errorMessage(from: data, status: http.statusCode))
        }
    }

    static func errorMessage(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String, !message.isEmpty {
            return String(message.prefix(120))
        }
        return "Nod answered \(status)."
    }
}