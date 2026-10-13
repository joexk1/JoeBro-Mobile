import Foundation

struct JoeBroAgentProfile: Decodable {
    let session: JBSession?
    let model: String
    let endpointID: String
    let permissionMode: String
    let soul: String

    enum CodingKeys: String, CodingKey {
        case session, model, soul
        case endpointID = "endpoint_id", permissionMode = "permission_mode"
    }
}

extension JoeBroAPI {
    func stopChat(sessionID: String) async throws {
        _ = try await send(OK.self, "api/chat/stop/\(segment(sessionID))")
    }



    func compactJoeBro() async throws -> CompactResult {
        try await send(CompactResult.self, "api/joebro/compact")
    }

    func clearJoeBro() async throws {
        _ = try await send(OK.self, "api/joebro/clear")
    }

    func joeBroProfile() async throws -> JoeBroAgentProfile {
        try await fetch(JoeBroAgentProfile.self, "api/joebro")
    }

    func openJoeBro() async throws -> JoeBroAgentProfile {
        try await send(JoeBroAgentProfile.self, "api/joebro/session")
    }

    func saveJoeBroSoul(_ soul: String) async throws {
        _ = try await send(OK.self, "api/joebro/soul", method: "PUT", json: ["soul": soul])
    }
}
