import Foundation

/// The two builds of this app share every source file. `PERSONAL` (set by the
/// Personal build configurations) switches on the owner's private add-ons in
/// `Personal/`; everything else differs only by the strings below.
enum Flavor {
    #if PERSONAL
    static let isPersonal = true
    #else
    static let isPersonal = false
    #endif

    /// Session id of the phone agent's single persistent chat (the backend's PHONE_SESSION_ID).
    static let mainSessionID = "joebro_ios_main"

    /// What the phone agent is called on its card, in the island and in task lists.
    static let mainAgentName = isPersonal ? "Personal Agent" : "JoeBro"
    static let mainAgentTasksHeader = isPersonal ? "JoeBro Personal Agent" : "JoeBro phone agent"
    static let brainTitle = isPersonal ? "Workspace Brain" : "Brain"
    static let memoryTitle = isPersonal ? "Personal Memory" : "Memory"
}
