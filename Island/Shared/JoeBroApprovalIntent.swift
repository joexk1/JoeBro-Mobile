import AppIntents

/// Lets the app register how a Live Activity button reaches the backend. The intent
/// runs in the app's process (LiveActivityIntent), where the pairing lives.
enum JoeBroApprovalBridge {
    nonisolated(unsafe) static var handler: ((String, Bool) async -> Void)?
}

/// Approve or deny a waiting coding agent from the Live Activity / Dynamic Island.
struct JoeBroApprovalIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Answer agent approval"
    static var openAppWhenRun = false

    @Parameter(title: "Agent") var agentID: String
    @Parameter(title: "Approve") var approve: Bool

    init() {}
    init(agentID: String, approve: Bool) {
        self.agentID = agentID
        self.approve = approve
    }

    func perform() async throws -> some IntentResult {
        await JoeBroApprovalBridge.handler?(agentID, approve)
        return .result()
    }
}
