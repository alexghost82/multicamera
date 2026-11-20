import Darwin
import Foundation
@testable import CameraCore

@main
struct IncidentAuditTransactionProcessHelper {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { exit(2) }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        let incident = root.appendingPathComponent("incidents.json")
        let audit = root.appendingPathComponent("audit.json")
        if args[2] == "manager-crash" || args[2] == "manager-evidence-crash" {
            let auditLog = OperatorAuditLog(url: audit)
            let manager = UnifiedIncidentManager(storageURL: incident, auditLog: auditLog) { boundary in
                if String(describing: boundary) == args[3] { _exit(44) }
            }
            guard let id = manager.allIncidents().first?.id else { exit(11) }
            if args[2] == "manager-evidence-crash" {
                _ = manager.clearEvidenceReferencesAndAudit(incidentID: id)
            } else {
                manager.updateOperatorNote(incidentID: id, note: "committed")
            }
            exit(12)
        }
        if args[2] == "strict-pause" || args[2] == "strict-recover-pause" {
            let store = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit) { boundary in
                if boundary == .afterIncidentPublication {
                    try FileHandle.standardOutput.write(contentsOf: Data([1]))
                    guard try FileHandle.standardInput.read(upToCount: 1) == Data([1]) else { _exit(8) }
                }
            }
            if args[2] == "strict-recover-pause" {
                _ = try store.snapshot()
            } else {
                _ = try store.update { snapshot in
                    .init(incidents: snapshot.incidents ?? Data("[]".utf8),
                          audit: snapshot.audit ?? Data("[]".utf8))
                }
            }
            return
        }
        if args[2] == "strict-nested" {
            let log = OperatorAuditLog(url: audit)
            let store = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit)
            _ = try store.update { snapshot in
                log.record(action: .settingsUpdated, summary: "nested")
                guard log.lastPersistenceError != nil else { _exit(9) }
                return .init(incidents: snapshot.incidents ?? Data("[]".utf8),
                             audit: snapshot.audit ?? Data("[]".utf8))
            }
            guard log.recentEntries().map(\.summary) == ["nested"], log.lastPersistenceError == nil else { exit(10) }
            return
        }
        if args[2] == "strict-crash" {
            let store = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit) { boundary in
                if String(describing: boundary) == args[3] { _exit(44) }
            }
            _ = try store.update { _ in
                .init(incidents: Data("[]".utf8), audit: Data("[]".utf8))
            }
            exit(3)
        }
        if args[2] == "crash" || args[2] == "recover-crash" {
            let store = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit,
                                                           validateCompatibility: { _, _ in }) { boundary in
                if String(describing: boundary) == args[3] { _exit(44) }
            }
            if args[2] == "recover-crash" {
                _ = try store.snapshot()
                exit(3)
            }
            _ = try store.update { _ in
                .init(incidents: Data("[{\"new\":1}]".utf8), audit: Data("[{\"new\":1}]".utf8))
            }
            exit(3)
        }
        if args[2] == "pause" {
            let store = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit,
                                                           validateCompatibility: { _, _ in }) { boundary in
                if boundary == .afterIncidentPublication {
                    try FileHandle.standardOutput.write(contentsOf: Data([1]))
                    guard try FileHandle.standardInput.read(upToCount: 1) == Data([1]) else { _exit(8) }
                }
            }
            _ = try store.update { _ in
                .init(incidents: Data("[{\"new\":1}]".utf8), audit: Data("[{\"new\":1}]".utf8))
            }
            return
        }
        if args[2] == "hold" {
            let fd = open(root.appendingPathComponent(".incident-audit.transaction.lock").path,
                          O_CREAT | O_RDWR, mode_t(0o600))
            guard fd >= 0, flock(fd, LOCK_EX) == 0 else { exit(4) }
            try FileHandle.standardOutput.write(contentsOf: Data([1]))
            guard try FileHandle.standardInput.read(upToCount: 1) == Data([1]) else { exit(5) }
            close(fd)
            return
        }
        guard args[2] == "write", let count = Int(args[3]) else { exit(6) }
        let store = try IncidentAuditTransactionStore(incidentURL: incident, auditURL: audit,
                                                       validateCompatibility: { _, _ in }, fault: { _ in })
        try FileHandle.standardOutput.write(contentsOf: Data([1]))
        guard try FileHandle.standardInput.read(upToCount: 1) == Data([1]) else { exit(5) }
        for index in 0..<count {
            let value = "\(getpid())-\(index)"
            var completed = false
            for _ in 0..<1000 {
                do {
                    try store.update { snapshot in
                        let old = try JSONSerialization.jsonObject(with: snapshot.incidents ?? Data("[]".utf8)) as! [String]
                        let next = try JSONSerialization.data(withJSONObject: old + [value])
                        return .init(incidents: next, audit: next)
                    }
                    completed = true
                    break
                } catch IncidentAuditTransactionStore.StoreError.busy {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            guard completed else { exit(7) }
        }
    }
}
