import Foundation

@main
struct SigningIdentityTests {
    static func main() {
        // ad-hoc: cdhash only → changes every build.
        let adhoc = SigningIdentityInspector.classify(
            requirementString: "cdhash H\"6abc8b9c1c1f4f4a2f1e0d3c8b7a695847362514\"")
        precondition(adhoc == .adhoc, "cdhash-only requirement must be ad-hoc")
        precondition(!adhoc.isStable, "ad-hoc must not count as stable")

        // Local self-signed certificate: identifier + pinned leaf hash.
        let local = SigningIdentityInspector.classify(
            requirementString: "identifier \"com.forgesweep.app\" and certificate leaf = H\"0011223344556677889900aabbccddeeff001122\"")
        precondition(local == .local, "pinned leaf requirement must be local")
        precondition(local.isStable, "local identity must be stable")

        // Apple Development: contains both `anchor apple` and `certificate leaf[...]`.
        let apple = SigningIdentityInspector.classify(
            requirementString: "identifier \"com.forgesweep.app\" and anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: Dev (TEAM1)\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */")
        precondition(apple == .apple, "Apple Development requirement must be classified as apple")
        precondition(apple.isStable, "Apple identity must be stable")

        // Developer ID.
        let developerID = SigningIdentityInspector.classify(
            requirementString: "anchor apple generic and identifier \"com.forgesweep.app\" and (certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = TEAM1)")
        precondition(developerID == .apple, "Developer ID requirement must be classified as apple")

        precondition(SigningIdentityInspector.classify(requirementString: "") == .unknown,
                     "empty requirement must be unknown")
        precondition(SigningIdentityInspector.classify(requirementString: "identifier \"x\"") == .unknown,
                     "identifier-only requirement must be unknown")

        // The running test binary is unsigned or ad-hoc; the inspector must
        // never crash and must return a consistent snapshot.
        let snapshot = SigningIdentityInspector.current()
        if let requirement = snapshot.requirement {
            precondition(SigningIdentityInspector.classify(requirementString: requirement) == snapshot.kind,
                         "snapshot kind must match its requirement text")
        } else {
            precondition(snapshot.kind == .unknown, "missing requirement must be unknown")
        }
        print("signing identity classification ok")

        // Preflight helper protocol: both permissions in one line, plus the
        // legacy single-digit screen-recording form.
        typealias Probe = PermissionCenter.LiveProbe
        precondition(Probe.parse("screen=1 disk=0\n") == Probe(screenRecording: true, fullDiskAccess: false),
                     "combined helper output must parse both fields")
        precondition(Probe.parse("screen=0 disk=1") == Probe(screenRecording: false, fullDiskAccess: true),
                     "combined helper output must parse both fields (reverse)")
        precondition(Probe.parse("1") == Probe(screenRecording: true, fullDiskAccess: nil),
                     "legacy helper output must still parse")
        precondition(Probe.parse("0") == Probe(screenRecording: false, fullDiskAccess: nil),
                     "legacy helper output must still parse")
        precondition(Probe.parse("garbage") == nil, "unknown helper output must be rejected")
        precondition(Probe.parse("") == nil, "empty helper output must be rejected")
        precondition(Probe.parse("screen=x disk=1") == Probe(screenRecording: nil, fullDiskAccess: true),
                     "unparseable field must degrade to nil without dropping the other field")
        let report = PermissionCenter.preflightReport()
        precondition(Probe.parse(report) != nil, "preflightReport must be parseable: \(report)")
        print("permission preflight protocol ok")

        testDiskAccessProbeFallback()
    }

    private static func testDiskAccessProbeFallback() {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("forgesweep-permission-tests-" + UUID().uuidString)
        try! manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let missing = directory.appendingPathComponent("missing-user.db").path
        let readable = directory.appendingPathComponent("system.db").path
        let denied = directory.appendingPathComponent("denied.db").path
        defer {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied)
            try? manager.removeItem(at: directory)
        }
        precondition(manager.createFile(atPath: readable, contents: Data()))
        precondition(manager.createFile(atPath: denied, contents: Data(),
                                        attributes: [.posixPermissions: 0o000]))

        precondition(!PermissionCenter.canOpenProtectedScanLocation(paths: [missing]),
                     "missing database must not imply authorization")
        precondition(PermissionCenter.canOpenProtectedScanLocation(paths: [readable, missing]),
                     "a readable first database must confirm access")
        precondition(PermissionCenter.canOpenProtectedScanLocation(paths: [missing, readable]),
                     "missing user database must fall back to the readable system database")
        precondition(!PermissionCenter.canOpenProtectedScanLocation(paths: [denied, missing]),
                     "an existing but unreadable database must not imply authorization")
        precondition(PermissionCenter.canOpenProtectedScanLocation(paths: [denied, readable]),
                     "an unreadable first database must not mask a readable fallback")
        print("full disk access probe: missing, denied and fallback cases ok")
    }
}
