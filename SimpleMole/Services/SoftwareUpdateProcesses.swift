import Darwin
import Foundation

enum SoftwareUpdateProcesses {
    struct Scope: Sendable {
        let roots: [String]
        var matchesScripts = false
        var applicationIdentities: Set<ProcessIdentity> = []
        static func app(_ app: UninstallApp) -> Scope { .init(roots: [app.path]) }
        static func tool(_ tool: CommandLineTool) -> Scope {
            // Removing an unowned launcher link does not authorize closing
            // the external executable that link happens to point at.
            if tool.agentInstallation?.onlyUnlinksExecutable == true { return .init(roots: []) }
            let paths = [tool.installationRoot] + tool.executablePaths
                + (tool.agentInstallation?.managedPaths ?? [])
                + (tool.agentInstallation?.executablePaths ?? [])
            return .init(roots: Array(Set(paths)).sorted(), matchesScripts: true)
        }
        func contains(_ path: String) -> Bool {
            guard path.hasPrefix("/"), DeletionPlan.isLexicallySafePath(path) else { return false }
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return roots.contains {
                guard DeletionPlan.isLexicallySafePath($0) else { return false }
                let root = URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                return canonical == root || canonical.hasPrefix(root + "/")
                    || path == $0 || path.hasPrefix($0 + "/")
            }
        }
    }
    struct Probe: Sendable {
        let processes: [ProcessSample]
        let isComplete: Bool
    }
    struct Environment {
        /// Fixtures may inject an array; production uses one complete native
        /// snapshot for both ownership and the idle check.
        var sample: (() -> [ProcessSample])? = nil
        var snapshot: () -> ProcessSampler.Snapshot = { ProcessSampler.shared.snapshot() }
        var current: (ProcessIdentity) -> ProcessSample? = { ProcessSampler.shared.current(for: $0) }
        var signal: (Int32, Int32) -> Bool = { kill($0, $1) == 0 }
        var pause: () async -> Void = { try? await Task.sleep(nanoseconds: 100_000_000) }
        var arguments: (Int32) -> [String]? = commandArguments
        var workingDirectory: (Int32) -> String? = currentDirectory
        var ownUID: UInt32 = getuid()
    }
    static func probe(_ scope: Scope, samples suppliedSamples: [ProcessSample]? = nil,
                      arguments: (Int32) -> [String]? = commandArguments,
                      workingDirectory: (Int32) -> String? = currentDirectory,
                      ownUID: UInt32 = getuid()) -> Probe {
        let snapshot = suppliedSamples.map { ProcessSampler.Snapshot(processes: $0, isComplete: true) }
            ?? ProcessSampler.shared.snapshot()
        let samples = snapshot.processes
        var complete = snapshot.isComplete
        let owned = samples.filter { sample in
            guard !sample.isZombie else { return false }
            if scope.applicationIdentities.contains(sample.identity) { return true }
            if scope.contains(sample.path) { return true }
            guard scope.matchesScripts, sample.uid == ownUID else { return false }
            let name = URL(fileURLWithPath: sample.path).lastPathComponent
            guard isInterpreter(name) else { return false }
            guard let argv = arguments(sample.pid) else { complete = false; return false }
            return scriptBelongs(argv, to: scope, directory: workingDirectory(sample.pid), interpreter: name)
        }
        return .init(processes: owned, isComplete: complete)
    }

    static func scriptBelongs(_ arguments: [String], to scope: Scope, directory: String? = nil,
                              interpreter: String? = nil) -> Bool {
        guard let executable = arguments.first else { return false }
        // The physical executable was checked by probe. argv[0] is mutable
        // and cannot independently authorize closing an unrelated process.
        let name = interpreter ?? URL(fileURLWithPath: executable).lastPathComponent
        guard isInterpreter(name) else { return false }
        if name == "java" { return javaTarget(arguments, belongsTo: scope, directory: directory) }
        // An interpreter's first script argument identifies the running tool;
        // arbitrary data-file arguments must never authorize process closure.
        var index = 1
        let shell = isShell(name)
        let python = name.hasPrefix("python") || name.hasPrefix("pypy")
        let valueOptions: Set<String>
        let booleanOptions: Set<String>
        if shell {
            valueOptions = ["-o", "+o", "-O", "+O", "--init-file", "--rcfile", "--features"]
            booleanOptions = ["--noprofile", "--norc", "--posix", "--restricted", "--verbose", "--login", "--no-execute", "--interactive"]
        } else if python {
            valueOptions = ["-X", "-W", "--check-hash-based-pycs"]
            booleanOptions = []
        } else {
            valueOptions = ["--require", "-r", "--loader", "--import", "--experimental-loader", "--conditions", "-C",
                "--inspect-port", "--title", "--watch-path", "--icu-data-dir", "--openssl-config", "--redirect-warnings",
                "--diagnostic-dir", "--report-directory", "--report-dir", "--report-filename", "--env-file", "--env-file-if-exists",
                "--heap-prof-dir", "--heap-prof-name", "--heap-prof-interval", "--cpu-prof-dir", "--cpu-prof-name", "--cpu-prof-interval",
                "--trace-event-categories", "--trace-event-file-pattern", "--tls-cipher-list", "--tls-keylog", "--input-type",
                "--unhandled-rejections", "--disable-proto", "--experimental-default-type", "--experimental-specifier-resolution",
                "--test-reporter", "--test-reporter-destination", "--test-name-pattern", "--test-skip-pattern", "--test-timeout", "--test-shard"]
            booleanOptions = ["-i", "--interactive", "--watch", "--watch-preserve-output", "--no-warnings", "--trace-warnings",
                "--trace-deprecation", "--no-deprecation", "--throw-deprecation", "--pending-deprecation", "--enable-source-maps",
                "--preserve-symlinks", "--preserve-symlinks-main", "--use-strict", "--experimental-modules", "--experimental-wasm-modules",
                "--experimental-vm-modules", "--experimental-strip-types", "--experimental-transform-types", "--no-experimental-strip-types",
                "--expose-gc", "--no-addons", "--zero-fill-buffers", "--inspect", "--inspect-brk", "--inspect-wait", "--check",
                "--trace-uncaught", "--trace-sync-io", "--trace-exit", "--test", "--cpu-prof", "--heap-prof"]
        }
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                return index < arguments.count && targetBelongs(arguments[index], to: scope, directory: directory)
            }
            if shell {
                // `-lc` evaluates command text; `-s` reads stdin and treats
                // later paths as data. Neither identifies an installed script.
                if argument.hasPrefix("-"), !argument.hasPrefix("--"),
                   argument.dropFirst().contains(where: { $0 == "c" || $0 == "s" }) { return false }
                if ["-C", "--command", "--init-command"].contains(argument)
                    || argument.hasPrefix("--command=") || argument.hasPrefix("--init-command=") { return false }
            } else {
                if ["-e", "-c", "-m", "-p", "--eval", "--print"].contains(argument)
                    || argument.hasPrefix("--eval=") || argument.hasPrefix("--print=") { return false }
            }
            if valueOptions.contains(argument) { index += 1; continue }
            if let equals = argument.firstIndex(of: "="), valueOptions.contains(String(argument[..<equals])) { continue }
            let attachedOptions = python ? ["-X", "-W"] : shell ? [] : ["-r", "-C"]
            if attachedOptions.contains(where: { argument.hasPrefix($0) && argument.count > $0.count }) { continue }
            if booleanOptions.contains(argument) { continue }
            if !shell, !python, ["--inspect=", "--inspect-brk=", "--inspect-wait="].contains(where: argument.hasPrefix) { continue }
            if argument.hasPrefix("-") || shell && argument.hasPrefix("+") {
                let shortFlags = shell ? "aAbBdDeEfFghHiIkKlLmMnNpPrRtTuvxX" : python ? "bBdEiIOPqRsSuvx" : "i"
                if !argument.hasPrefix("--"), argument.count > 1,
                   argument.dropFirst().allSatisfy({ shortFlags.contains($0) }) { continue }
                // An unknown option might consume the next value. It cannot
                // be skipped and let that value masquerade as the script.
                return false
            }
            return targetBelongs(argument, to: scope, directory: directory)
        }
        return false
    }

    private static func isShell(_ name: String) -> Bool {
        ["sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh"].contains(name)
    }
    private static func isInterpreter(_ name: String) -> Bool {
        name == "node" || name == "nodejs" || name.hasPrefix("python") || name.hasPrefix("pypy")
            || isShell(name) || name == "java"
    }
    private static func targetBelongs(_ path: String, to scope: Scope, directory: String?) -> Bool {
        if path.hasPrefix("/") { return scope.contains(path) }
        guard let directory else { return false }
        return scope.contains(URL(fileURLWithPath: directory).appendingPathComponent(path).standardizedFileURL.path)
    }
    private static func javaTarget(_ arguments: [String], belongsTo scope: Scope, directory: String?) -> Bool {
        let valueOptions: Set<String> = ["-cp", "-classpath", "--class-path", "-p", "--module-path",
            "--upgrade-module-path", "--add-modules", "--source", "--enable-native-access", "--patch-module",
            "--add-exports", "--add-opens", "--add-reads", "--limit-modules", "--module-version", "--describe-module"]
        let booleanOptions: Set<String> = ["--enable-preview", "-esa", "-enablesystemassertions", "-dsa", "-disablesystemassertions",
            "-ea", "-enableassertions", "-da", "-disableassertions", "-server", "-client", "-showversion", "--show-version"]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "-jar" {
                guard index < arguments.count else { return false }
                return targetBelongs(arguments[index], to: scope, directory: directory)
            }
            if ["-m", "--module"].contains(argument) || argument.hasPrefix("--module=") { return false }
            if valueOptions.contains(argument) { index += 1; continue }
            if let equals = argument.firstIndex(of: "="), valueOptions.contains(String(argument[..<equals])) { continue }
            if booleanOptions.contains(argument) { continue }
            // These JVM option families carry their value in the same token.
            if ["-D", "-X", "-verbose:", "-agentlib:", "-agentpath:", "-javaagent:", "-ea:", "-da:"].contains(where: {
                argument.hasPrefix($0) && argument.count > $0.count
            }) { continue }
            if argument.hasPrefix("-") { return false }
            // Java's other entry point is a class name. Only source-file mode
            // supplies a physical script path; classpaths/data are not owners.
            return argument.hasSuffix(".java") && targetBelongs(argument, to: scope, directory: directory)
        }
        return false
    }

    /// Read only argv from KERN_PROCARGS2; never retain or display environment values.
    static func commandArguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 512 else { return nil }
        var index = 4
        while index < size, bytes[index] != 0 { index += 1 } // executable path
        while index < size, bytes[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<count {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            guard index < size, let argument = String(bytes: bytes[start..<index], encoding: .utf8) else { return nil }
            result.append(argument); index += 1
        }
        return result
    }
    static func currentDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Only called after consent to close the scoped software. Revalidate argv,
    /// executable and start identity immediately before each signal.
    @MainActor
    static func close(_ scope: Scope, ownPID own: Int32 = ProcessInfo.processInfo.processIdentifier,
                      environment env: Environment = Environment(), stillCurrent: () -> Bool) async -> Bool {
        func probeCurrent(_ samples: [ProcessSample]) -> Probe {
            probe(scope, samples: samples, arguments: env.arguments,
                  workingDirectory: env.workingDirectory, ownUID: env.ownUID)
        }
        func processSnapshot() -> ProcessSampler.Snapshot {
            env.sample.map { .init(processes: $0(), isComplete: true) } ?? env.snapshot()
        }
        for pass in 0..<30 {
            guard !Task.isCancelled, stillCurrent() else { return false }
            let snapshot = processSnapshot()
            guard snapshot.isComplete else { return false }
            let samples = snapshot.processes
            let current = probeCurrent(samples)
            guard current.isComplete else { return false }
            if current.processes.isEmpty { return true }
            let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            for target in current.processes {
                var parent = target.pid
                var seen = Set<Int32>()
                while parent > 1, seen.insert(parent).inserted {
                    if parent == own { return false }
                    parent = byPID[parent]?.ppid ?? 0
                }
                parent = own; seen.removeAll()
                while parent > 1, seen.insert(parent).inserted {
                    if parent == target.pid { return false }
                    parent = byPID[parent]?.ppid ?? 0
                }
                guard target.pid > 1, target.uid == env.ownUID,
                      target.pid != own else { return false }
                guard let fresh = env.current(target.identity) else { continue }
                guard fresh.identity == target.identity, fresh.path == target.path,
                      probeCurrent([fresh]).processes.count == 1 else { return false }
                let signal = pass < 15 ? SIGTERM : SIGKILL
                guard stillCurrent() else { return false }
                if !env.signal(target.pid, signal), env.current(target.identity) != nil { return false }
            }
            await env.pause()
        }
        let finalSnapshot = processSnapshot()
        let final = probeCurrent(finalSnapshot.processes)
        return stillCurrent() && finalSnapshot.isComplete && final.isComplete && final.processes.isEmpty
    }
}
