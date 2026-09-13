import AppIntents

enum HafaRemoteDestination: String, AppEnum {
    case remote

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Hafa Remote Screen")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .remote: "Remote"
    ]
}

/// Opens the app at its remembered remote without moving credentials into an extension.
struct OpenHafaRemoteIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Hafa Remote"
    static let description = IntentDescription("Opens your last-used TV remote.")

    @Parameter(title: "Destination")
    var target: HafaRemoteDestination

    init() {
        target = .remote
    }
}
