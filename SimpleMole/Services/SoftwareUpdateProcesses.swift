import Darwin
import Foundation

enum SoftwareUpdateProcesses {
    struct Scope: Sendable {
        let roots: [String]
        var matchesScripts = false
        var applicationIdentities: Set<ProcessIdentity> = []
        static func app(_ app: UninstallApp) -> Scope { .init(roots: [app.path]) }
        static func tool(_ tool: CommandLineTool) -> Scope {
            if tool.manager == .homebrew {
                let path = URL(fileURLWithPath: tool.path)
                return .init(roots: [path.lastPathComponent == tool.name ? path.path : path.deletingLastPathComponent().path])
            }
            return .init(roots: [tool.path] + tool.executablePaths,
                         matchesScripts: [.npm, .pnpm, .pipx, .uv].contains(tool.manager))
        }
        func contains(_ path: String) -> Bool {
            guard path.hasPrefix("/"), DeletionPlan.isLexicallySafePath(path) else { return false }
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return roots.contains {
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
    static func probe(_ scope: Scope, samples: [ProcessSample] = ProcessSampler.shared.sample(),
                      arguments: (Int32) -> [String]? = commandArguments,
                      workingDirectory: (Int32) -> String? = currentDirectory) -> Probe {
        var complete = true
        let owned = samples.filter { sample in
            guard !sample.isZombie else { return false }
            if scope.applicationIdentities.contains(sample.identity) { return true }
            if scope.contains(sample.path) { return true }
            guard scope.matchesScripts, sample.uid == getuid() else { return false }
            let name = URL(fileURLWithPath: sample.path).lastPathComponent
            guard name == "node" || name.hasPrefix("python") || name.hasPrefix("pypy") else { return false }
            guard let argv = arguments(sample.pid) else { complete = false; return false }
            return scriptBelongs(argv, to: scope, directory: workingDirectory(sample.pid))
        }
        return .init(processes: owned, isComplete: complete)
    }

    static func scriptBelongs(_ arguments: [String], to scope: Scope, directory: String? = nil) -> Bool {
        guard let executable = arguments.first else { return false }
        if scope.contains(executable) { return true }
        // An interpreter's first script argument identifies the running tool;
        // arbitrary data-file arguments must never authorize process closure.
        var index = 1
        let valueOptions: Set<String> = ["--require", "-r", "--loader", "--import", "--experimental-loader", "--conditions", "--inspect-port", "--title", "-X", "-W"]
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" { continue }
            if ["-e", "-c", "-m", "--eval"].contains(argument) { return false }
            if valueOptions.contains(argument) { index += 1; continue }
            if argument.hasPrefix("-") { continue }
            if argument.hasPrefix("/") { return scope.contains(argument) }
            guard let directory else { return false }
            return scope.contains(URL(fileURLWithPath: directory).appendingPathComponent(argument).standardizedFileURL.path)
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
    static func close(_ scope: Scope, ownPID own: Int32 = ProcessInfo.processInfo.processIdentifier,
                      stillCurrent: () -> Bool) async -> Bool {
        for pass in 0..<30 {
            guard !Task.isCancelled, stillCurrent() else { return false }
            let samples = ProcessSampler.shared.sample()
            let current = probe(scope, samples: samples)
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
                guard target.pid > 1, target.uid == getuid(),
                      target.pid != own else { return false }
                guard let fresh = ProcessSampler.shared.current(for: target.identity) else { continue }
                guard fresh.path == target.path, probe(scope, samples: [fresh]).processes.count == 1 else { return false }
                let signal = pass < 15 ? SIGTERM : SIGKILL
                guard stillCurrent() else { return false }
                if kill(target.pid, signal) != 0, ProcessSampler.shared.current(for: target.identity) != nil { return false }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let final = probe(scope)
        return stillCurrent() && final.isComplete && final.processes.isEmpty
    }
}
