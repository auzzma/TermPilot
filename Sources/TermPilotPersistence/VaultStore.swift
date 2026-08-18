import Foundation
import GRDB
import Network
import TermPilotDomain

public actor VaultStore {
    private let database: DatabasePool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let credentialCipher: VaultCredentialCipher

    public init(databaseURL: URL, credentialKeyURL: URL? = nil) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        database = try DatabasePool(
            path: databaseURL.path,
            configuration: configuration
        )
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        credentialCipher = try VaultCredentialCipher(
            keyURL: credentialKeyURL
                ?? databaseURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("credential.key")
        )
        try Self.makeMigrator().migrate(database)
    }

    public static func openDefault(
        fileManager: FileManager = .default
    ) throws -> VaultStore {
        let directory = try applicationSupportDirectory(fileManager: fileManager)
        return try VaultStore(databaseURL: directory.appendingPathComponent("vault.sqlite"))
    }

    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent("TermPilot", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    public func fetchHosts(search: String = "") throws -> [TermPilotDomain.Host] {
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.read { db in
            let records: [HostRecord]
            if search.isEmpty {
                records = try HostRecord
                    .order(
                        Column("group_id"),
                        Column("sort_order"),
                        Column("label").collating(.localizedCaseInsensitiveCompare)
                    )
                    .fetchAll(db)
            } else {
                let pattern = "%\(search)%"
                records = try HostRecord
                    .filter(
                        Column("label").like(pattern)
                            || Column("hostname").like(pattern)
                            || Column("username").like(pattern)
                    )
                    .order(
                        Column("group_id"),
                        Column("sort_order"),
                        Column("label").collating(.localizedCaseInsensitiveCompare)
                    )
                    .fetchAll(db)
            }
            return try records.compactMap {
                try $0.host(credentialCipher: credentialCipher)
            }
        }
    }

    public func fetchHost(id: UUID) throws -> TermPilotDomain.Host? {
        try database.read { db in
            try HostRecord.fetchOne(db, key: id.uuidString)?
                .host(credentialCipher: credentialCipher)
        }
    }

    public func saveHost(_ host: TermPilotDomain.Host) throws {
        var validated = try host.validated()
        validated.updatedAt = Date()
        try database.write { db in
            let existing = try HostRecord.fetchOne(
                db,
                key: validated.id.uuidString
            )
            if existing == nil || existing?.groupID != validated.groupID?.uuidString {
                validated.sortOrder = try Self.nextHostSortOrder(
                    inGroup: validated.groupID?.uuidString,
                    db: db
                )
            }
            try HostRecord(
                host: validated,
                credentialCipher: credentialCipher
            ).save(db)
        }
    }

    public func fetchCredentials() throws -> [SSHCredential] {
        try database.read { db in
            try SSHCredentialRecord
                .order(Column("label").collating(.localizedCaseInsensitiveCompare))
                .fetchAll(db)
                .compactMap {
                    try $0.credential(credentialCipher: credentialCipher)
                }
        }
    }

    public func saveCredential(_ credential: SSHCredential) throws {
        var validated = try credential.validated()
        validated.updatedAt = Date()
        try database.write { db in
            try SSHCredentialRecord(
                credential: validated,
                credentialCipher: credentialCipher
            ).save(db)
        }
    }

    public func deleteCredential(id: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE hosts
                    SET credential_reference = NULL, updated_at = ?
                    WHERE credential_reference = ?
                    """,
                arguments: [Date(), id.uuidString]
            )
            try SSHCredentialRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func fetchProxyProfiles() throws -> [SSHProxyProfile] {
        try database.read { db in
            try SSHProxyProfileRecord
                .order(
                    Column("sort_order"),
                    Column("created_at"),
                    Column("label").collating(.localizedCaseInsensitiveCompare)
                )
                .fetchAll(db)
                .compactMap {
                    try $0.profile(credentialCipher: credentialCipher)
                }
        }
    }

    public func saveProxyProfile(_ profile: SSHProxyProfile) throws {
        var validated = try profile.validated()
        validated.updatedAt = Date()
        try database.write { db in
            let existing = try SSHProxyProfileRecord.fetchOne(
                db,
                key: validated.id.uuidString
            )
            try SSHProxyProfileRecord(
                profile: validated,
                credentialCipher: credentialCipher,
                sortOrder: existing?.sortOrder
                    ?? Self.nextProxyProfileSortOrder(db: db)
            ).save(db)
        }
    }

    public func reorderProxyProfiles(ids: [UUID]) throws {
        try database.write { db in
            try Self.persistSortOrder(
                ids: ids,
                table: SSHProxyProfileRecord.databaseTableName,
                db: db
            )
        }
    }

    public func deleteProxyProfile(id: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE hosts
                    SET proxy_profile_reference = NULL, updated_at = ?
                    WHERE proxy_profile_reference = ?
                    """,
                arguments: [Date(), id.uuidString]
            )
            try SSHProxyProfileRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func importSnapshot(
        hosts: [TermPilotDomain.Host],
        groups: [HostGroup]
    ) throws {
        try database.write { db in
            for group in groups {
                let trimmedName = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else {
                    throw PersistenceError.emptyGroupName
                }
                var copy = group
                copy.name = trimmedName
                try Self.validateGroupParent(copy, db: db)
                try GroupRecord(group: copy).save(db)
            }
            for host in hosts {
                var validated = try host.validated()
                validated.updatedAt = Date()
                try HostRecord(
                    host: validated,
                    credentialCipher: credentialCipher
                ).save(db)
            }
        }
    }

    public func makeBackupSnapshot() throws -> TermPilotBackupSnapshot {
        try database.read { db in
            let hosts = try HostRecord
                .order(
                    Column("group_id"),
                    Column("sort_order"),
                    Column("label")
                )
                .fetchAll(db)
                .compactMap {
                    try $0.host(credentialCipher: credentialCipher)
                }
            let groups = try GroupRecord
                .order(
                    Column("parent_group_id"),
                    Column("sort_order"),
                    Column("name")
                )
                .fetchAll(db)
                .compactMap(\.group)
            let credentials = try SSHCredentialRecord
                .order(Column("label"))
                .fetchAll(db)
                .compactMap {
                    try $0.credential(
                        credentialCipher: credentialCipher
                    )
                }
            let proxyProfiles = try SSHProxyProfileRecord
                .order(Column("sort_order"), Column("created_at"))
                .fetchAll(db)
                .compactMap {
                    try $0.profile(
                        credentialCipher: credentialCipher
                    )
                }
            let portForwardRules = try PortForwardRuleRecord
                .order(Column("updated_at").desc)
                .fetchAll(db)
                .map {
                    try $0.rule(decoder: decoder)
                }
            let scripts = try AutomationScriptRecord
                .order(Column("sort_order"), Column("updated_at"))
                .fetchAll(db)
                .map {
                    try $0.script(decoder: decoder)
                }
            let scriptIDs = Set(scripts.map(\.id))
            let legacyScripts = try SnippetRecord
                .order(Column("updated_at").desc)
                .fetchAll(db)
                .compactMap {
                    try $0.automationScript(decoder: decoder)
                }
                .filter {
                    !scriptIDs.contains($0.id)
                }
            let hostNotes = try HostNoteRecord
                .order(Column("updated_at").desc)
                .fetchAll(db)
                .map {
                    try $0.note(decoder: decoder)
                }
            return TermPilotBackupSnapshot(
                hosts: hosts,
                groups: groups,
                credentials: credentials,
                proxyProfiles: proxyProfiles,
                portForwardRules: portForwardRules,
                automationScripts: scripts + legacyScripts,
                hostNotes: hostNotes
            )
        }
    }

    public func importBackupSnapshot(
        _ snapshot: TermPilotBackupSnapshot
    ) throws -> BackupImportSummary {
        guard snapshot.schemaVersion
                == TermPilotBackupSnapshot.currentSchemaVersion
        else {
            throw EncryptedBackupError.unsupportedSnapshotVersion
        }
        return try database.write { db in
            for credential in snapshot.credentials {
                let validated = try credential.validated()
                try SSHCredentialRecord(
                    credential: validated,
                    credentialCipher: credentialCipher
                ).save(db)
            }
            let credentialIDs = Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM ssh_credentials"
                ).compactMap(UUID.init(uuidString:))
            )

            let existingProxyRecords =
                try SSHProxyProfileRecord.fetchAll(db)
            let existingProxySortOrders = Dictionary(
                uniqueKeysWithValues: existingProxyRecords.compactMap {
                    record in
                    UUID(uuidString: record.id).map {
                        ($0, record.sortOrder)
                    }
                }
            )
            var nextProxySortOrder =
                (existingProxyRecords.map(\.sortOrder).max() ?? -1) + 1
            for profile in snapshot.proxyProfiles {
                var validated = try profile.validated()
                if let credentialID =
                    validated.configuration.credentialID,
                    !credentialIDs.contains(credentialID)
                {
                    validated.configuration.credentialID = nil
                }
                let sortOrder =
                    existingProxySortOrders[validated.id]
                    ?? nextProxySortOrder
                if existingProxySortOrders[validated.id] == nil {
                    nextProxySortOrder += 1
                }
                try SSHProxyProfileRecord(
                    profile: validated,
                    credentialCipher: credentialCipher,
                    sortOrder: sortOrder
                ).save(db)
            }
            let proxyProfileIDs = Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM ssh_proxy_profiles"
                ).compactMap(UUID.init(uuidString:))
            )

            let existingGroupIDs = Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM host_groups"
                ).compactMap(UUID.init(uuidString:))
            )
            let orderedGroups = try Self.orderedBackupGroups(
                snapshot.groups,
                existingGroupIDs: existingGroupIDs
            )
            for group in orderedGroups {
                var validated = group
                validated.name = group.name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !validated.name.isEmpty else {
                    throw PersistenceError.emptyGroupName
                }
                try Self.validateGroupParent(validated, db: db)
                try GroupRecord(group: validated).save(db)
            }
            let groupIDs = Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM host_groups"
                ).compactMap(UUID.init(uuidString:))
            )

            let existingHosts = try HostRecord
                .fetchAll(db)
                .compactMap {
                    try $0.host(credentialCipher: credentialCipher)
                }
            let existingHostIDs = Set(existingHosts.map(\.id))
            var hostIDByIdentity: [String: UUID] = [:]
            for host in existingHosts {
                hostIDByIdentity[
                    Self.normalizedBackupHostIdentity(host.hostname),
                    default: host.id
                ] = host.id
            }
            var hostIDReplacements: [UUID: UUID] = [:]
            var deduplicatedHostIDs = Set<UUID>()
            for host in snapshot.hosts {
                let identity = Self.normalizedBackupHostIdentity(
                    host.hostname
                )
                if let existingID = hostIDByIdentity[identity] {
                    hostIDReplacements[host.id] = existingID
                    if existingID != host.id
                        || existingHostIDs.contains(existingID)
                    {
                        deduplicatedHostIDs.insert(host.id)
                    }
                } else {
                    hostIDReplacements[host.id] = host.id
                    hostIDByIdentity[identity] = host.id
                }
            }

            var savedHostIDs = Set<UUID>()
            for host in snapshot.hosts {
                guard let targetID = hostIDReplacements[host.id],
                      savedHostIDs.insert(targetID).inserted
                else {
                    continue
                }
                var imported = host
                imported.id = targetID
                if let existing = existingHosts.first(where: {
                    $0.id == targetID
                }) {
                    imported.createdAt = existing.createdAt
                }
                if imported.groupID.map({
                    !groupIDs.contains($0)
                }) == true {
                    imported.groupID = nil
                }
                if imported.credentialID.map({
                    !credentialIDs.contains($0)
                }) == true {
                    imported.credentialID = nil
                }
                if imported.proxyProfileID.map({
                    !proxyProfileIDs.contains($0)
                }) == true {
                    imported.proxyProfileID = nil
                }
                if var proxy = imported.proxyConfiguration,
                   let credentialID = proxy.credentialID,
                   !credentialIDs.contains(credentialID)
                {
                    proxy.credentialID = nil
                    imported.proxyConfiguration = proxy
                }
                imported = try imported.validated()
                try HostRecord(
                    host: imported,
                    credentialCipher: credentialCipher
                ).save(db)
            }

            let availableHostIDs = Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM hosts"
                ).compactMap(UUID.init(uuidString:))
            )
            func mappedHostID(_ id: UUID?) -> UUID? {
                guard let id else {
                    return nil
                }
                return hostIDReplacements[id]
                    ?? (availableHostIDs.contains(id) ? id : nil)
            }

            for rule in snapshot.portForwardRules {
                var imported = rule
                imported.hostID = mappedHostID(rule.hostID)
                imported.status = .inactive
                imported.error = nil
                imported = try imported.validated()
                try PortForwardRuleRecord(
                    rule: imported,
                    encoder: encoder
                ).save(db)
            }

            let existingScriptRecords =
                try AutomationScriptRecord.fetchAll(db)
            let existingScriptSortOrders = Dictionary(
                uniqueKeysWithValues: existingScriptRecords.compactMap {
                    record in
                    UUID(uuidString: record.id).map {
                        ($0, record.sortOrder)
                    }
                }
            )
            var nextScriptSortOrder =
                (existingScriptRecords.map(\.sortOrder).max() ?? -1) + 1
            for script in snapshot.automationScripts {
                let validated = try script.validated()
                let sortOrder =
                    existingScriptSortOrders[validated.id]
                    ?? nextScriptSortOrder
                if existingScriptSortOrders[validated.id] == nil {
                    nextScriptSortOrder += 1
                }
                try AutomationScriptRecord(
                    script: validated,
                    encoder: encoder,
                    sortOrder: sortOrder
                ).save(db)
                _ = try? SnippetRecord.deleteOne(
                    db,
                    key: validated.id.uuidString
                )
            }

            for note in snapshot.hostNotes {
                var imported = note
                imported.hostID = mappedHostID(note.hostID)
                imported = try imported.validated()
                try HostNoteRecord(
                    note: imported,
                    encoder: encoder
                ).save(db)
            }

            return BackupImportSummary(
                hosts: savedHostIDs.count,
                deduplicatedHosts: deduplicatedHostIDs.count,
                groups: snapshot.groups.count,
                credentials: snapshot.credentials.count,
                proxyProfiles: snapshot.proxyProfiles.count,
                portForwardRules: snapshot.portForwardRules.count,
                automationScripts: snapshot.automationScripts.count,
                hostNotes: snapshot.hostNotes.count
            )
        }
    }

    public func deleteHost(id: UUID) throws {
        _ = try database.write { db in
            try HostRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func moveHosts(
        ids: Set<UUID>,
        toGroup groupID: UUID?
    ) throws {
        try moveHosts(ids: ids, toGroup: groupID, beforeHostID: nil)
    }

    public func moveHosts(
        ids: Set<UUID>,
        toGroup groupID: UUID?,
        beforeHostID: UUID?
    ) throws {
        guard !ids.isEmpty else {
            return
        }
        let updatedAt = Date()
        try database.write { db in
            try Self.reorderHosts(
                ids: Set(ids.map(\.uuidString)),
                toGroupID: groupID?.uuidString,
                beforeHostID: beforeHostID?.uuidString,
                updatedAt: updatedAt,
                db: db
            )
        }
    }

    public func assignProxyProfile(
        toHosts ids: Set<UUID>,
        proxyProfileID: UUID
    ) throws {
        guard !ids.isEmpty else {
            return
        }
        let updatedAt = Date()
        try database.write { db in
            for id in ids {
                try db.execute(
                    sql: """
                        UPDATE hosts
                        SET proxy_profile_reference = ?,
                            proxy_type = NULL,
                            proxy_host = NULL,
                            proxy_port = NULL,
                            proxy_command = NULL,
                            proxy_credential_reference = NULL,
                            proxy_username = NULL,
                            proxy_password = NULL,
                            updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        proxyProfileID.uuidString,
                        updatedAt,
                        id.uuidString,
                    ]
                )
            }
        }
    }

    public func disableProxy(
        forHosts ids: Set<UUID>
    ) throws {
        guard !ids.isEmpty else {
            return
        }
        let updatedAt = Date()
        try database.write { db in
            for id in ids {
                try db.execute(
                    sql: """
                        UPDATE hosts
                        SET proxy_profile_reference = NULL,
                            proxy_type = NULL,
                            proxy_host = NULL,
                            proxy_port = NULL,
                            proxy_command = NULL,
                            proxy_credential_reference = NULL,
                            proxy_username = NULL,
                            proxy_password = NULL,
                            updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        updatedAt,
                        id.uuidString,
                    ]
                )
            }
        }
    }

    public func fetchGroups() throws -> [HostGroup] {
        try database.read { db in
            try GroupRecord
                .order(Column("parent_group_id"), Column("sort_order"), Column("name"))
                .fetchAll(db)
                .compactMap(\.group)
        }
    }

    public func saveGroup(_ group: HostGroup) throws {
        let trimmedName = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw PersistenceError.emptyGroupName
        }
        guard group.parentGroupID != group.id else {
            throw PersistenceError.invalidGroupParent
        }
        var copy = group
        copy.name = trimmedName
        try database.write { db in
            try Self.validateGroupParent(copy, db: db)
            try GroupRecord(group: copy).save(db)
        }
    }

    public func moveGroup(
        id: UUID,
        toParent parentGroupID: UUID?,
        beforeGroupID: UUID?
    ) throws {
        try database.write { db in
            guard let group = try GroupRecord.fetchOne(db, key: id.uuidString)
            else {
                return
            }
            var moved = group
            moved.parentGroupID = parentGroupID?.uuidString
            try Self.validateGroupParent(
                HostGroup(
                    id: id,
                    name: group.name,
                    parentGroupID: parentGroupID,
                    sortOrder: group.sortOrder
                ),
                db: db
            )
            try Self.reorderGroups(
                movedGroup: moved,
                toParentID: parentGroupID?.uuidString,
                beforeGroupID: beforeGroupID?.uuidString,
                db: db
            )
        }
    }

    public func deleteGroup(id: UUID) throws {
        try database.write { db in
            let records = try GroupRecord.fetchAll(db)
            let childrenByParent = Dictionary(grouping: records) {
                $0.parentGroupID ?? ""
            }
            var visited = Set<String>()
            var deletionOrder: [String] = []

            func appendToDeletionOrder(_ groupID: String) {
                guard visited.insert(groupID).inserted else {
                    return
                }
                for child in childrenByParent[groupID] ?? [] {
                    appendToDeletionOrder(child.id)
                }
                deletionOrder.append(groupID)
            }

            appendToDeletionOrder(id.uuidString)

            let updatedAt = Date()
            for groupID in deletionOrder {
                try db.execute(
                    sql: """
                        UPDATE hosts
                        SET group_id = NULL, updated_at = ?
                        WHERE group_id = ?
                        """,
                    arguments: [updatedAt, groupID]
                )
                _ = try GroupRecord.deleteOne(db, key: groupID)
            }
        }
    }

    public func appendHistory(_ entry: ConnectionHistoryEntry) throws {
        try database.write { db in
            try HistoryRecord(entry: entry).insert(db)
            try db.execute(
                sql: """
                    DELETE FROM connection_history
                    WHERE id IN (
                        SELECT id FROM connection_history
                        ORDER BY started_at DESC
                        LIMIT -1 OFFSET 1000
                    )
                    """
            )
        }
    }

    public func fetchHistory(limit: Int = 100) throws -> [ConnectionHistoryEntry] {
        try database.read { db in
            try HistoryRecord
                .order(Column("started_at").desc)
                .limit(max(1, min(limit, 1000)))
                .fetchAll(db)
                .compactMap(\.entry)
        }
    }

    public func fetchPortForwardRules() throws -> [PortForwardRule] {
        try database.read { db in
            try PortForwardRuleRecord
                .order(Column("updated_at").desc)
                .fetchAll(db)
                .map { try $0.rule(decoder: decoder) }
        }
    }

    public func savePortForwardRule(_ rule: PortForwardRule) throws {
        var copy = try rule.validated()
        copy.updatedAt = Date()
        try database.write { db in
            try PortForwardRuleRecord(rule: copy, encoder: encoder).save(db)
        }
    }

    public func deletePortForwardRule(id: UUID) throws {
        _ = try database.write { db in
            try PortForwardRuleRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func fetchLegacyAutomationScriptsFromSnippets() throws -> [AutomationScript] {
        try database.read { db in
            try SnippetRecord
                .order(Column("updated_at").desc)
                .fetchAll(db)
                .compactMap { try $0.automationScript(decoder: decoder) }
        }
    }

    public func deleteLegacySnippet(id: UUID) throws {
        _ = try database.write { db in
            try SnippetRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func fetchAutomationScripts() throws -> [AutomationScript] {
        try database.read { db in
            try AutomationScriptRecord
                .order(Column("sort_order"), Column("updated_at"))
                .fetchAll(db)
                .map { try $0.script(decoder: decoder) }
        }
    }

    public func saveAutomationScript(_ script: AutomationScript) throws {
        var copy = try script.validated()
        copy.updatedAt = Date()
        try database.write { db in
            let existing = try AutomationScriptRecord.fetchOne(
                db,
                key: copy.id.uuidString
            )
            try AutomationScriptRecord(
                script: copy,
                encoder: encoder,
                sortOrder: existing?.sortOrder
                    ?? Self.nextAutomationScriptSortOrder(db: db)
            ).save(db)
        }
    }

    public func reorderAutomationScripts(ids: [UUID]) throws {
        try database.write { db in
            try Self.persistSortOrder(
                ids: ids,
                table: AutomationScriptRecord.databaseTableName,
                db: db
            )
        }
    }

    public func deleteAutomationScript(id: UUID) throws {
        _ = try database.write { db in
            try AutomationScriptRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func fetchHostNotes(hostID: UUID? = nil) throws -> [HostNote] {
        try database.read { db in
            let records: [HostNoteRecord]
            if let hostID {
                records = try HostNoteRecord
                    .filter(Column("host_id") == hostID.uuidString)
                    .order(Column("updated_at").desc)
                    .fetchAll(db)
            } else {
                records = try HostNoteRecord
                    .order(Column("updated_at").desc)
                    .fetchAll(db)
            }
            return try records.map { try $0.note(decoder: decoder) }
        }
    }

    public func saveHostNote(_ note: HostNote) throws {
        var copy = try note.validated()
        copy.updatedAt = Date()
        try database.write { db in
            try HostNoteRecord(note: copy, encoder: encoder).save(db)
        }
    }

    public func deleteHostNote(id: UUID) throws {
        _ = try database.write { db in
            try HostNoteRecord.deleteOne(db, key: id.uuidString)
        }
    }

    public func eraseWorkspaceSnapshot() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM workspace_state WHERE id = 1")
        }
    }

    private static func orderedBackupGroups(
        _ groups: [HostGroup],
        existingGroupIDs: Set<UUID>
    ) throws -> [HostGroup] {
        var remaining: [UUID: HostGroup] = [:]
        for group in groups {
            remaining[group.id] = group
        }
        var resolved = existingGroupIDs
        var result: [HostGroup] = []
        while !remaining.isEmpty {
            let ready = remaining.values
                .filter {
                    $0.parentGroupID == nil
                        || $0.parentGroupID.map(resolved.contains) == true
                }
                .sorted {
                    if $0.sortOrder == $1.sortOrder {
                        return $0.name.localizedCaseInsensitiveCompare(
                            $1.name
                        ) == .orderedAscending
                    }
                    return $0.sortOrder < $1.sortOrder
                }
            guard !ready.isEmpty else {
                throw PersistenceError.invalidGroupParent
            }
            for group in ready {
                remaining.removeValue(forKey: group.id)
                resolved.insert(group.id)
                result.append(group)
            }
        }
        return result
    }

    private static func normalizedBackupHostIdentity(
        _ hostname: String
    ) -> String {
        var value = hostname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasPrefix("["),
           value.hasSuffix("]")
        {
            value.removeFirst()
            value.removeLast()
        }
        if let address = IPv4Address(value) {
            return "ipv4:\(address.debugDescription)"
        }
        if let address = IPv6Address(value) {
            return "ipv6:\(address.debugDescription)"
        }
        if value.hasSuffix(".") {
            value.removeLast()
        }
        return "host:\(value)"
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "host_groups") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("sort_order", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "hosts") { table in
                table.column("id", .text).primaryKey()
                table.column("label", .text).notNull()
                table.column("hostname", .text).notNull()
                table.column("port", .integer).notNull()
                table.column("username", .text).notNull()
                table.column("authentication", .text).notNull()
                table.column("identity_file", .text)
                table.column("credential_reference", .text)
                table.column("group_id", .text)
                    .references("host_groups", onDelete: .setNull)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(
                index: "hosts_search",
                on: "hosts",
                columns: ["label", "hostname", "username"]
            )

            try db.create(table: "connection_history") { table in
                table.column("id", .text).primaryKey()
                table.column("host_id", .text)
                    .references("hosts", onDelete: .setNull)
                table.column("started_at", .datetime).notNull()
                table.column("ended_at", .datetime)
                table.column("succeeded", .boolean).notNull()
                table.column("error_category", .text)
            }

            try db.create(table: "workspace_state") { table in
                table.column("id", .integer).primaryKey()
                table.column("payload", .blob).notNull()
                table.column("saved_at", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2-host-password") { db in
            try db.alter(table: "hosts") { table in
                table.add(column: "password", .text)
            }
        }
        migrator.registerMigration("v3-host-group-parent") { db in
            try db.alter(table: "host_groups") { table in
                table.add(column: "parent_group_id", .text)
                    .references("host_groups", onDelete: .setNull)
            }
        }
        migrator.registerMigration("v4-host-sftp-options") { db in
            try db.alter(table: "hosts") { table in
                table.add(column: "sftp_file_protocol", .text)
                    .notNull()
                    .defaults(to: SFTPFileProtocol.auto.rawValue)
                table.add(column: "sftp_filename_encoding", .text)
                    .notNull()
                    .defaults(to: SFTPFilenameEncoding.auto.rawValue)
                table.add(column: "sftp_uses_sudo", .boolean)
                    .notNull()
                    .defaults(to: false)
                table.add(column: "sftp_follows_terminal_cwd", .boolean)
            }
        }
        migrator.registerMigration("v5-phase-5-7-local-workflows") { db in
            try db.create(table: "port_forward_rules") { table in
                table.column("id", .text).primaryKey()
                table.column("host_id", .text)
                    .references("hosts", onDelete: .setNull)
                table.column("payload", .blob).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "port_forward_rules_host", on: "port_forward_rules", columns: ["host_id"])

            try db.create(table: "snippets") { table in
                table.column("id", .text).primaryKey()
                table.column("payload", .blob).notNull()
                table.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "automation_scripts") { table in
                table.column("id", .text).primaryKey()
                table.column("payload", .blob).notNull()
                table.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "host_notes") { table in
                table.column("id", .text).primaryKey()
                table.column("host_id", .text)
                    .references("hosts", onDelete: .setNull)
                table.column("payload", .blob).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "host_notes_host", on: "host_notes", columns: ["host_id"])
        }
        migrator.registerMigration("v6-ssh-credentials") { db in
            try db.create(table: "ssh_credentials") { table in
                table.column("id", .text).primaryKey()
                table.column("label", .text).notNull()
                table.column("username", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("password", .text)
                table.column("private_key", .text)
                table.column("public_key", .text)
                table.column("certificate", .text)
                table.column("passphrase", .text)
                table.column("saves_passphrase", .boolean).notNull().defaults(to: false)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(
                index: "ssh_credentials_label",
                on: "ssh_credentials",
                columns: ["label"]
            )
        }
        migrator.registerMigration("v7-credential-elevation-password") { db in
            try db.alter(table: "ssh_credentials") { table in
                table.add(column: "elevation_password", .text)
            }
        }
        migrator.registerMigration("v8-ssh-proxies") { db in
            try db.create(table: "ssh_proxy_profiles") { table in
                table.column("id", .text).primaryKey()
                table.column("label", .text).notNull()
                table.column("type", .text).notNull()
                table.column("host", .text).notNull()
                table.column("port", .integer).notNull()
                table.column("command", .text)
                table.column("credential_reference", .text)
                table.column("username", .text)
                table.column("password", .text)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(
                index: "ssh_proxy_profiles_label",
                on: "ssh_proxy_profiles",
                columns: ["label"]
            )
            try db.alter(table: "hosts") { table in
                table.add(column: "proxy_profile_reference", .text)
                table.add(column: "proxy_type", .text)
                table.add(column: "proxy_host", .text)
                table.add(column: "proxy_port", .integer)
                table.add(column: "proxy_command", .text)
                table.add(column: "proxy_credential_reference", .text)
                table.add(column: "proxy_username", .text)
                table.add(column: "proxy_password", .text)
            }
        }
        migrator.registerMigration("v9-remove-external-protocols") { db in
            try db.execute(
                sql: "DROP TABLE IF EXISTS external_protocol_profiles"
            )
        }
        migrator.registerMigration("v10-host-appearance") { db in
            try db.alter(table: "hosts") { table in
                table.add(column: "distro", .text)
                table.add(column: "distro_mode", .text)
                    .notNull()
                    .defaults(to: HostDistroMode.auto.rawValue)
                table.add(column: "manual_distro", .text)
                table.add(column: "icon_mode", .text)
                    .notNull()
                    .defaults(to: HostIconMode.auto.rawValue)
                table.add(column: "icon_id", .text)
                table.add(column: "icon_color_mode", .text)
                    .notNull()
                    .defaults(to: HostIconColorMode.auto.rawValue)
                table.add(column: "icon_color", .text)
                table.add(column: "icon_color_custom", .text)
            }
        }
        migrator.registerMigration("v11-server-tools-root") { db in
            try db.alter(table: "hosts") { table in
                table.add(column: "server_tools_use_root", .boolean)
                    .notNull()
                    .defaults(to: false)
            }
            try db.execute(
                sql: """
                UPDATE hosts
                SET server_tools_use_root = sftp_uses_sudo
                WHERE sftp_uses_sudo = 1
                """
            )
        }
        migrator.registerMigration("v12-server-tools-elevation-method") { db in
            try db.alter(table: "hosts") { table in
                table.add(column: "server_tools_elevation_method", .text)
                    .notNull()
                    .defaults(to: ServerToolsElevationMethod.sudo.rawValue)
            }
        }
        migrator.registerMigration("v13-host-sort-order") { db in
            try db.alter(table: "hosts") { table in
                table.add(column: "sort_order", .integer)
                    .notNull()
                    .defaults(to: 0)
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, group_id
                    FROM hosts
                    ORDER BY group_id, label COLLATE NOCASE, label
                    """
            )
            var nextOrderByGroup: [String: Int] = [:]
            for row in rows {
                let id: String = row["id"]
                let groupID: String? = row["group_id"]
                let groupKey = groupID ?? ""
                let sortOrder = nextOrderByGroup[groupKey, default: 0]
                nextOrderByGroup[groupKey] = sortOrder + 1
                try db.execute(
                    sql: "UPDATE hosts SET sort_order = ? WHERE id = ?",
                    arguments: [sortOrder, id]
                )
            }
        }
        migrator.registerMigration("v14-remove-host-last-connected") { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(hosts)")
            let hasLastConnectedAt = columns.contains { row in
                let name: String = row["name"]
                return name == "last_connected_at"
            }
            if hasLastConnectedAt {
                try db.execute(
                    sql: "ALTER TABLE hosts DROP COLUMN last_connected_at"
                )
            }
        }
        migrator.registerMigration("v15-proxy-script-sort-order") { db in
            try db.alter(table: "ssh_proxy_profiles") { table in
                table.add(column: "sort_order", .integer)
                    .notNull()
                    .defaults(to: 0)
            }
            try db.alter(table: "automation_scripts") { table in
                table.add(column: "sort_order", .integer)
                    .notNull()
                    .defaults(to: 0)
            }

            let proxyIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM ssh_proxy_profiles
                    ORDER BY created_at, id
                    """
            )
            try persistSortOrder(
                ids: proxyIDs.compactMap(UUID.init(uuidString:)),
                table: "ssh_proxy_profiles",
                db: db
            )

            let scriptIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT id
                    FROM automation_scripts
                    ORDER BY updated_at, id
                    """
            )
            try persistSortOrder(
                ids: scriptIDs.compactMap(UUID.init(uuidString:)),
                table: "automation_scripts",
                db: db
            )
        }
        return migrator
    }

    private static func nextProxyProfileSortOrder(
        db: Database
    ) throws -> Int {
        (
            try Int.fetchOne(
                db,
                sql: "SELECT MAX(sort_order) FROM ssh_proxy_profiles"
            ) ?? -1
        ) + 1
    }

    private static func nextAutomationScriptSortOrder(
        db: Database
    ) throws -> Int {
        (
            try Int.fetchOne(
                db,
                sql: "SELECT MAX(sort_order) FROM automation_scripts"
            ) ?? -1
        ) + 1
    }

    private static func persistSortOrder(
        ids: [UUID],
        table: String,
        db: Database
    ) throws {
        for (sortOrder, id) in ids.enumerated() {
            try db.execute(
                sql: "UPDATE \(table) SET sort_order = ? WHERE id = ?",
                arguments: [sortOrder, id.uuidString]
            )
        }
    }

    private static func nextHostSortOrder(
        inGroup groupID: String?,
        db: Database
    ) throws -> Int {
        let sql: String
        let arguments: StatementArguments
        if let groupID {
            sql = "SELECT MAX(sort_order) FROM hosts WHERE group_id = ?"
            arguments = [groupID]
        } else {
            sql = "SELECT MAX(sort_order) FROM hosts WHERE group_id IS NULL"
            arguments = []
        }
        return (try Int.fetchOne(db, sql: sql, arguments: arguments) ?? -1) + 1
    }

    private static func reorderHosts(
        ids: Set<String>,
        toGroupID groupID: String?,
        beforeHostID: String?,
        updatedAt: Date,
        db: Database
    ) throws {
        let allRows = try fetchHostOrderRows(db: db)
        let movingRows = allRows.filter { ids.contains($0.id) }
        guard !movingRows.isEmpty else {
            return
        }
        if let beforeHostID,
           ids.contains(beforeHostID)
        {
            return
        }

        var targetIDs = allRows
            .filter { $0.groupID == groupID && !ids.contains($0.id) }
            .map(\.id)
        let insertIndex = beforeHostID
            .flatMap { targetIDs.firstIndex(of: $0) }
            ?? targetIDs.count
        targetIDs.insert(contentsOf: movingRows.map(\.id), at: insertIndex)

        for (sortOrder, id) in targetIDs.enumerated() {
            try db.execute(
                sql: """
                    UPDATE hosts
                    SET group_id = ?, sort_order = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [groupID, sortOrder, updatedAt, id]
            )
        }

        let sourceGroupIDs = Set(movingRows.map(\.groupID))
            .filter { $0 != groupID }
        for sourceGroupID in sourceGroupIDs {
            try normalizeHostSortOrder(
                inGroup: sourceGroupID,
                updatedAt: updatedAt,
                db: db
            )
        }
    }

    private static func normalizeHostSortOrder(
        inGroup groupID: String?,
        updatedAt: Date,
        db: Database
    ) throws {
        let rows = try fetchHostOrderRows(inGroup: groupID, db: db)
        for (sortOrder, row) in rows.enumerated() {
            try db.execute(
                sql: """
                    UPDATE hosts
                    SET sort_order = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [sortOrder, updatedAt, row.id]
            )
        }
    }

    private static func fetchHostOrderRows(db: Database) throws -> [HostOrderRow] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT id, group_id, sort_order
                FROM hosts
                ORDER BY group_id, sort_order, label COLLATE NOCASE, label
                """
        ).map(HostOrderRow.init(row:))
    }

    private static func fetchHostOrderRows(
        inGroup groupID: String?,
        db: Database
    ) throws -> [HostOrderRow] {
        let sql: String
        let arguments: StatementArguments
        if let groupID {
            sql = """
                SELECT id, group_id, sort_order
                FROM hosts
                WHERE group_id = ?
                ORDER BY sort_order, label COLLATE NOCASE, label
                """
            arguments = [groupID]
        } else {
            sql = """
                SELECT id, group_id, sort_order
                FROM hosts
                WHERE group_id IS NULL
                ORDER BY sort_order, label COLLATE NOCASE, label
                """
            arguments = []
        }
        return try Row.fetchAll(db, sql: sql, arguments: arguments)
            .map(HostOrderRow.init(row:))
    }

    private static func reorderGroups(
        movedGroup: GroupRecord,
        toParentID parentID: String?,
        beforeGroupID: String?,
        db: Database
    ) throws {
        if let beforeGroupID,
           beforeGroupID == movedGroup.id
        {
            return
        }

        var targetIDs = try fetchGroupOrderRows(inParent: parentID, db: db)
            .filter { $0.id != movedGroup.id }
            .map(\.id)
        let insertIndex = beforeGroupID
            .flatMap { targetIDs.firstIndex(of: $0) }
            ?? targetIDs.count
        targetIDs.insert(movedGroup.id, at: insertIndex)

        for (sortOrder, id) in targetIDs.enumerated() {
            try db.execute(
                sql: """
                    UPDATE host_groups
                    SET parent_group_id = ?, sort_order = ?
                    WHERE id = ?
                    """,
                arguments: [parentID, sortOrder, id]
            )
        }

        if movedGroup.parentGroupID != parentID {
            try normalizeGroupSortOrder(
                inParent: movedGroup.parentGroupID,
                db: db
            )
        }
    }

    private static func normalizeGroupSortOrder(
        inParent parentID: String?,
        db: Database
    ) throws {
        let rows = try fetchGroupOrderRows(inParent: parentID, db: db)
        for (sortOrder, row) in rows.enumerated() {
            try db.execute(
                sql: """
                    UPDATE host_groups
                    SET sort_order = ?
                    WHERE id = ?
                    """,
                arguments: [sortOrder, row.id]
            )
        }
    }

    private static func fetchGroupOrderRows(
        inParent parentID: String?,
        db: Database
    ) throws -> [GroupOrderRow] {
        let sql: String
        let arguments: StatementArguments
        if let parentID {
            sql = """
                SELECT id
                FROM host_groups
                WHERE parent_group_id = ?
                ORDER BY sort_order, name COLLATE NOCASE, name
                """
            arguments = [parentID]
        } else {
            sql = """
                SELECT id
                FROM host_groups
                WHERE parent_group_id IS NULL
                ORDER BY sort_order, name COLLATE NOCASE, name
                """
            arguments = []
        }
        return try Row.fetchAll(db, sql: sql, arguments: arguments)
            .map(GroupOrderRow.init(row:))
    }

    private static func validateGroupParent(
        _ group: HostGroup,
        db: Database
    ) throws {
        var parentID = group.parentGroupID?.uuidString
        var visited = Set<String>()
        while let current = parentID,
              visited.insert(current).inserted
        {
            if current == group.id.uuidString {
                throw PersistenceError.invalidGroupParent
            }
            parentID = try String.fetchOne(
                db,
                sql: "SELECT parent_group_id FROM host_groups WHERE id = ?",
                arguments: [current]
            )
        }
    }
}

public enum PersistenceError: Error, Equatable, Sendable {
    case emptyGroupName
    case invalidGroupParent
    case invalidCredentialKey
    case credentialKeyGenerationFailed(Int32)
    case credentialEncryptionFailed
    case credentialDecryptionFailed
}

private struct HostOrderRow {
    var id: String
    var groupID: String?
    var sortOrder: Int

    init(row: Row) {
        id = row["id"]
        groupID = row["group_id"]
        sortOrder = row["sort_order"]
    }
}

private struct GroupOrderRow {
    var id: String

    init(row: Row) {
        id = row["id"]
    }
}

private struct HostRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "hosts"

    var id: String
    var label: String
    var hostname: String
    var port: Int
    var username: String
    var authentication: String
    var identityFile: String?
    var password: String?
    var credentialReference: String?
    var proxyProfileReference: String?
    var proxyType: String?
    var proxyHost: String?
    var proxyPort: Int?
    var proxyCommand: String?
    var proxyCredentialReference: String?
    var proxyUsername: String?
    var proxyPassword: String?
    var groupID: String?
    var sortOrder: Int
    var distro: String?
    var distroMode: String?
    var manualDistro: String?
    var iconMode: String?
    var iconID: String?
    var iconColorMode: String?
    var iconColor: String?
    var iconColorCustom: String?
    var sftpFileProtocol: String?
    var sftpFilenameEncoding: String?
    var sftpUsesSudo: Bool?
    var sftpFollowsTerminalCWD: Bool?
    var serverToolsUseRoot: Bool?
    var serverToolsElevationMethod: String?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case hostname
        case port
        case username
        case authentication
        case identityFile = "identity_file"
        case password
        case credentialReference = "credential_reference"
        case proxyProfileReference = "proxy_profile_reference"
        case proxyType = "proxy_type"
        case proxyHost = "proxy_host"
        case proxyPort = "proxy_port"
        case proxyCommand = "proxy_command"
        case proxyCredentialReference = "proxy_credential_reference"
        case proxyUsername = "proxy_username"
        case proxyPassword = "proxy_password"
        case groupID = "group_id"
        case sortOrder = "sort_order"
        case distro
        case distroMode = "distro_mode"
        case manualDistro = "manual_distro"
        case iconMode = "icon_mode"
        case iconID = "icon_id"
        case iconColorMode = "icon_color_mode"
        case iconColor = "icon_color"
        case iconColorCustom = "icon_color_custom"
        case sftpFileProtocol = "sftp_file_protocol"
        case sftpFilenameEncoding = "sftp_filename_encoding"
        case sftpUsesSudo = "sftp_uses_sudo"
        case sftpFollowsTerminalCWD = "sftp_follows_terminal_cwd"
        case serverToolsUseRoot = "server_tools_use_root"
        case serverToolsElevationMethod =
            "server_tools_elevation_method"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        host: TermPilotDomain.Host,
        credentialCipher: VaultCredentialCipher
    ) throws {
        id = host.id.uuidString
        label = host.label
        hostname = host.hostname
        port = host.port
        username = host.username
        authentication = host.authentication.rawValue
        identityFile = host.identityFile
        password = try credentialCipher.encryptField(host.password)
        credentialReference = host.credentialID?.uuidString
        proxyProfileReference = host.proxyProfileID?.uuidString
        proxyType = host.proxyConfiguration?.type.rawValue
        proxyHost = host.proxyConfiguration?.host
        proxyPort = host.proxyConfiguration?.port
        proxyCommand = host.proxyConfiguration?.command
        proxyCredentialReference = host.proxyConfiguration?.credentialID?.uuidString
        proxyUsername = host.proxyConfiguration?.username
        proxyPassword = try credentialCipher.encryptField(
            host.proxyConfiguration?.password
        )
        groupID = host.groupID?.uuidString
        sortOrder = host.sortOrder
        distro = host.distro?.rawValue
        distroMode = host.distroMode.rawValue
        manualDistro = host.manualDistro?.rawValue
        iconMode = host.iconMode.rawValue
        iconID = host.iconID?.rawValue
        iconColorMode = host.iconColorMode.rawValue
        iconColor = host.iconColor?.rawValue
        iconColorCustom = host.iconColorCustom
        sftpFileProtocol = host.sftpFileProtocol.rawValue
        sftpFilenameEncoding = host.sftpFilenameEncoding.rawValue
        sftpUsesSudo = host.sftpUsesSudo
        sftpFollowsTerminalCWD = host.sftpFollowsTerminalCWD
        serverToolsUseRoot = host.serverToolsUseRoot
        serverToolsElevationMethod =
            host.serverToolsElevationMethod.rawValue
        createdAt = host.createdAt
        updatedAt = host.updatedAt
    }

    func host(
        credentialCipher: VaultCredentialCipher
    ) throws -> TermPilotDomain.Host? {
        guard let id = UUID(uuidString: id),
              let authentication = AuthenticationMethod(rawValue: authentication)
        else {
            return nil
        }
        let sftpProtocol = SFTPFileProtocol(
            rawValue: sftpFileProtocol ?? SFTPFileProtocol.auto.rawValue
        ) ?? .auto
        let sftpEncoding = SFTPFilenameEncoding(
            rawValue: sftpFilenameEncoding ?? SFTPFilenameEncoding.auto.rawValue
        ) ?? .auto
        let proxyConfiguration = try proxyType
            .flatMap(SSHProxyType.init(rawValue:))
            .map {
                SSHProxyConfiguration(
                    type: $0,
                    host: proxyHost ?? "",
                    port: proxyPort ?? 0,
                    command: proxyCommand,
                    credentialID: proxyCredentialReference.flatMap(
                        UUID.init(uuidString:)
                    ),
                    username: proxyUsername,
                    password: try credentialCipher.decryptField(proxyPassword)
                )
            }
        return TermPilotDomain.Host(
            id: id,
            label: label,
            hostname: hostname,
            port: port,
            username: username,
            authentication: authentication,
            identityFile: identityFile,
            password: try credentialCipher.decryptField(password),
            credentialID: credentialReference.flatMap(UUID.init(uuidString:)),
            proxyProfileID: proxyProfileReference.flatMap(UUID.init(uuidString:)),
            proxyConfiguration: proxyConfiguration,
            groupID: groupID.flatMap(UUID.init(uuidString:)),
            sortOrder: sortOrder,
            distro: distro.flatMap(HostDistroID.init(rawValue:)),
            distroMode: distroMode.flatMap(HostDistroMode.init(rawValue:))
                ?? .auto,
            manualDistro: manualDistro.flatMap(HostDistroID.init(rawValue:)),
            iconMode: iconMode.flatMap(HostIconMode.init(rawValue:)) ?? .auto,
            iconID: iconID.flatMap(HostIconID.init(rawValue:)),
            iconColorMode: iconColorMode.flatMap(
                HostIconColorMode.init(rawValue:)
            ) ?? .auto,
            iconColor: iconColor.flatMap(HostIconColorID.init(rawValue:)),
            iconColorCustom: iconColorCustom,
            sftpFileProtocol: sftpProtocol,
            sftpFilenameEncoding: sftpEncoding,
            sftpUsesSudo: sftpProtocol == .scp ? false : (sftpUsesSudo ?? false),
            sftpFollowsTerminalCWD: sftpFollowsTerminalCWD,
            serverToolsUseRoot: serverToolsUseRoot ?? false,
            serverToolsElevationMethod: serverToolsElevationMethod
                .flatMap(ServerToolsElevationMethod.init(rawValue:))
                ?? .sudo,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct GroupRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "host_groups"

    var id: String
    var name: String
    var parentGroupID: String?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case parentGroupID = "parent_group_id"
        case sortOrder = "sort_order"
    }

    init(group: HostGroup) {
        id = group.id.uuidString
        name = group.name
        parentGroupID = group.parentGroupID?.uuidString
        sortOrder = group.sortOrder
    }

    var group: HostGroup? {
        UUID(uuidString: id).map {
            HostGroup(
                id: $0,
                name: name,
                parentGroupID: parentGroupID.flatMap(UUID.init(uuidString:)),
                sortOrder: sortOrder
            )
        }
    }
}

private struct SSHCredentialRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ssh_credentials"

    var id: String
    var label: String
    var username: String
    var kind: String
    var password: String?
    var privateKey: String?
    var publicKey: String?
    var certificate: String?
    var passphrase: String?
    var savesPassphrase: Bool
    var elevationPassword: String?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case username
        case kind
        case password
        case privateKey = "private_key"
        case publicKey = "public_key"
        case certificate
        case passphrase
        case savesPassphrase = "saves_passphrase"
        case elevationPassword = "elevation_password"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        credential: SSHCredential,
        credentialCipher: VaultCredentialCipher
    ) throws {
        id = credential.id.uuidString
        label = credential.label
        username = credential.username
        kind = credential.kind.rawValue
        password = try credentialCipher.encryptField(credential.password)
        privateKey = try credentialCipher.encryptField(credential.privateKey)
        publicKey = credential.publicKey
        certificate = credential.certificate
        passphrase = try credentialCipher.encryptField(credential.passphrase)
        savesPassphrase = credential.savesPassphrase
        elevationPassword = try credentialCipher.encryptField(
            credential.elevationPassword
        )
        createdAt = credential.createdAt
        updatedAt = credential.updatedAt
    }

    func credential(
        credentialCipher: VaultCredentialCipher
    ) throws -> SSHCredential? {
        guard let id = UUID(uuidString: id),
              let kind = SSHCredentialKind(rawValue: kind)
        else {
            return nil
        }
        return SSHCredential(
            id: id,
            label: label,
            username: username,
            kind: kind,
            password: try credentialCipher.decryptField(password),
            privateKey: try credentialCipher.decryptField(privateKey),
            publicKey: publicKey,
            certificate: certificate,
            passphrase: try credentialCipher.decryptField(passphrase),
            savesPassphrase: savesPassphrase,
            elevationPassword: try credentialCipher.decryptField(
                elevationPassword
            ),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct SSHProxyProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ssh_proxy_profiles"

    var id: String
    var label: String
    var type: String
    var host: String
    var port: Int
    var command: String?
    var credentialReference: String?
    var username: String?
    var password: String?
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case type
        case host
        case port
        case command
        case credentialReference = "credential_reference"
        case username
        case password
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        profile: SSHProxyProfile,
        credentialCipher: VaultCredentialCipher,
        sortOrder: Int
    ) throws {
        id = profile.id.uuidString
        label = profile.label
        type = profile.configuration.type.rawValue
        host = profile.configuration.host
        port = profile.configuration.port
        command = profile.configuration.command
        credentialReference = profile.configuration.credentialID?.uuidString
        username = profile.configuration.username
        password = try credentialCipher.encryptField(
            profile.configuration.password
        )
        self.sortOrder = sortOrder
        createdAt = profile.createdAt
        updatedAt = profile.updatedAt
    }

    func profile(
        credentialCipher: VaultCredentialCipher
    ) throws -> SSHProxyProfile? {
        guard let id = UUID(uuidString: id),
              let type = SSHProxyType(rawValue: type)
        else {
            return nil
        }
        return SSHProxyProfile(
            id: id,
            label: label,
            configuration: SSHProxyConfiguration(
                type: type,
                host: host,
                port: port,
                command: command,
                credentialID: credentialReference.flatMap(UUID.init(uuidString:)),
                username: username,
                password: try credentialCipher.decryptField(password)
            ),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct HistoryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "connection_history"

    var id: String
    var hostID: String?
    var startedAt: Date
    var endedAt: Date?
    var succeeded: Bool
    var errorCategory: String?

    enum CodingKeys: String, CodingKey {
        case id
        case hostID = "host_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case succeeded
        case errorCategory = "error_category"
    }

    init(entry: ConnectionHistoryEntry) {
        id = entry.id.uuidString
        hostID = entry.hostID?.uuidString
        startedAt = entry.startedAt
        endedAt = entry.endedAt
        succeeded = entry.succeeded
        errorCategory = entry.errorCategory
    }

    var entry: ConnectionHistoryEntry? {
        guard let id = UUID(uuidString: id) else {
            return nil
        }
        return ConnectionHistoryEntry(
            id: id,
            hostID: hostID.flatMap(UUID.init(uuidString:)),
            startedAt: startedAt,
            endedAt: endedAt,
            succeeded: succeeded,
            errorCategory: errorCategory
        )
    }
}

private struct PortForwardRuleRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "port_forward_rules"

    var id: String
    var hostID: String?
    var payload: Data
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case hostID = "host_id"
        case payload
        case updatedAt = "updated_at"
    }

    init(rule: PortForwardRule, encoder: JSONEncoder) throws {
        id = rule.id.uuidString
        hostID = rule.hostID?.uuidString
        payload = try encoder.encode(rule)
        updatedAt = rule.updatedAt
    }

    func rule(decoder: JSONDecoder) throws -> PortForwardRule {
        try decoder.decode(PortForwardRule.self, from: payload)
    }
}

private struct SnippetRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "snippets"

    var id: String
    var payload: Data
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case payload
        case updatedAt = "updated_at"
    }

    func automationScript(decoder: JSONDecoder) throws -> AutomationScript? {
        let legacy = try decoder.decode(LegacySnippetPayload.self, from: payload)
        guard legacy.kind == "script" else {
            return nil
        }
        let title = legacy.title ?? legacy.label ?? "Imported Script"
        let body = legacy.body ?? legacy.command ?? ""
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return AutomationScript(
            id: legacy.id ?? UUID(uuidString: id) ?? UUID(),
            title: title,
            shell: "/bin/sh",
            body: body,
            createdAt: legacy.createdAt ?? updatedAt,
            updatedAt: legacy.updatedAt ?? updatedAt
        )
    }
}

private struct LegacySnippetPayload: Decodable {
    var id: UUID?
    var title: String?
    var label: String?
    var body: String?
    var command: String?
    var kind: String?
    var createdAt: Date?
    var updatedAt: Date?
}

private struct AutomationScriptRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "automation_scripts"

    var id: String
    var payload: Data
    var updatedAt: Date
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case payload
        case updatedAt = "updated_at"
        case sortOrder = "sort_order"
    }

    init(
        script: AutomationScript,
        encoder: JSONEncoder,
        sortOrder: Int
    ) throws {
        id = script.id.uuidString
        payload = try encoder.encode(script)
        updatedAt = script.updatedAt
        self.sortOrder = sortOrder
    }

    func script(decoder: JSONDecoder) throws -> AutomationScript {
        try decoder.decode(AutomationScript.self, from: payload)
    }
}

private struct HostNoteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "host_notes"

    var id: String
    var hostID: String?
    var payload: Data
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case hostID = "host_id"
        case payload
        case updatedAt = "updated_at"
    }

    init(note: HostNote, encoder: JSONEncoder) throws {
        id = note.id.uuidString
        hostID = note.hostID?.uuidString
        payload = try encoder.encode(note)
        updatedAt = note.updatedAt
    }

    func note(decoder: JSONDecoder) throws -> HostNote {
        try decoder.decode(HostNote.self, from: payload)
    }
}
