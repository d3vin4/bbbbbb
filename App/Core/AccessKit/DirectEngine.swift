import Foundation

/// A container (app data or App Group) discovered on the device.
struct ContainerRecord: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case application
        case appGroup

        var title: String {
            switch self {
            case .application: return "Application"
            case .appGroup: return "App Group"
            }
        }

        var mcmClass: UInt64 {
            switch self {
            case .application: return 2
            case .appGroup: return 7
            }
        }
    }

    let identifier: String
    let kind: Kind
    let path: String

    var id: String { "\(kind.rawValue):\(identifier)" }
}

/// Direct container access engine (MHA-C2 + fallback strategies) backed by
/// BadQueryCore (Objective-C).
final class DirectEngine {
    static let shared = DirectEngine()

    private init() {}

    struct CapabilityReport {
        var mcmAvailable: Bool
        var mhaIdentity: Bool
        var appGroups: [String]

        var isMHAReady: Bool { mcmAvailable && mhaIdentity }
    }

    func capabilityReport() -> CapabilityReport {
        CapabilityReport(
            mcmAvailable: BQCore.isAvailable(),
            mhaIdentity: BQCore.hasMHAIdentity(),
            appGroups: BQCore.appGroupIdentifiers()
        )
    }

    /// Installed apps: bundle identifier + data container path.
    func fetchApplications(limit: Int = 600) throws -> [ContainerRecord] {
        let identifiers = BQCore.enumerateIdentifiers(
            forClass: ContainerRecord.Kind.application.mcmClass,
            limit: UInt(limit)
        )
        guard !identifiers.isEmpty else {
            throw Self.error(from: "liệt kê ứng dụng")
        }

        var records: [ContainerRecord] = []
        records.reserveCapacity(identifiers.count)
        for identifier in identifiers {
            let containerPath: String? = BQCore.containerPath(
                forClass: ContainerRecord.Kind.application.mcmClass,
                identifier: identifier,
                group: false
            )
            if let containerPath {
                records.append(ContainerRecord(identifier: identifier, kind: .application, path: containerPath))
            }
        }
        return records
    }

    /// App Group containers: group identifier + container path.
    func fetchAppGroups(limit: Int = 600) throws -> [ContainerRecord] {
        let identifiers = BQCore.enumerateIdentifiers(
            forClass: ContainerRecord.Kind.appGroup.mcmClass,
            limit: UInt(limit)
        )
        guard !identifiers.isEmpty else {
            throw Self.error(from: "liệt kê App Group")
        }

        var records: [ContainerRecord] = []
        records.reserveCapacity(identifiers.count)
        for identifier in identifiers {
            let containerPath: String? = BQCore.containerPath(
                forClass: ContainerRecord.Kind.appGroup.mcmClass,
                identifier: identifier,
                group: true
            )
            if let containerPath {
                records.append(ContainerRecord(identifier: identifier, kind: .appGroup, path: containerPath))
            }
        }
        return records
    }

    /// Activates a retained lease for the container and returns its path.
    @discardableResult
    func activate(_ record: ContainerRecord) throws -> String {
        let activatedPath: String? = BQCore.activateContainer(
            forClass: record.kind.mcmClass,
            identifier: record.identifier,
            group: record.kind == .appGroup
        )
        guard let activatedPath else {
            throw Self.error(from: "kích hoạt \(record.identifier)")
        }
        return activatedPath
    }

    /// Directory listing that falls back to fsgetpath enumeration when readdir
    /// is denied inside the container.
    func listDirectory(at path: String) throws -> [String] {
        let url = URL(fileURLWithPath: path)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            return entries.map(\.lastPathComponent)
        }
        let enumerated = BQCore.listDirectoryEntries(path, maxInode: 2_000_000)
        return enumerated.map { ($0 as NSString).lastPathComponent }
    }

    func releaseLeases() {
        BQCore.releaseLeases()
    }

    private static func error(from context: String) -> NSError {
        NSError(
            domain: "BQCoreErrorDomain",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: BQCore.lastErrorDescription() ?? "\(context) thất bại"]
        )
    }
}
