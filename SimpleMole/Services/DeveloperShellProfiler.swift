import Foundation

enum DeveloperShellProfiler {
    struct Result: Sendable { let median: TimeInterval?; let functions: String; let failed: Bool }
    static func profile(shell: String = DeveloperTerminalEnvironmentService.defaultShell(), home: String = NSHomeDirectory(), engine: MoleEngine = MoleEngine()) async -> Result {
        guard ["/bin/zsh", "/bin/bash"].contains(shell) else { return .init(median: nil, functions: "", failed: true) }
        var environment = engine.standardEnvironment()
        environment["HOME"] = home
        environment["DISABLE_AUTO_UPDATE"] = "true"
        environment["DISABLE_UPDATE_PROMPT"] = "true"
        environment["POWERLEVEL9K_INSTANT_PROMPT"] = "off"
        var timings: [TimeInterval] = []
        for _ in 0..<5 {
            guard !Task.isCancelled else { return .init(median: nil, functions: "", failed: true) }
            let start = Date()
            let result = await engine.run(executable: URL(fileURLWithPath: shell), arguments: ["-lic", ":"], environment: environment,
                                           currentDirectory: URL(fileURLWithPath: home), timeout: 10)
            guard result.succeeded else { return .init(median: nil, functions: "", failed: true) }
            timings.append(Date().timeIntervalSince(start))
        }
        var functions = ""
        if shell == "/bin/zsh" {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nori-zprof-" + UUID().uuidString)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                // Temporary startup entry enables profiling before the original configuration.
                let original = DeveloperShellService.inventory(home: home, shellPath: shell, environment: environment).directory
                let entry = "zmodload zsh/zprof\n" + "[[ -f " + DeveloperCLIService.shellQuote(original + "/.zshrc") + " ]] && source " + DeveloperCLIService.shellQuote(original + "/.zshrc") + "\n"
                let file = directory.appendingPathComponent(".zshrc")
                try Data(entry.utf8).write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                environment["ZDOTDIR"] = directory.path
                let result = await engine.run(executable: URL(fileURLWithPath: shell), arguments: ["-ic", "zprof"], environment: environment, currentDirectory: URL(fileURLWithPath: home), timeout: 10)
                if result.succeeded { functions = DeveloperSecretRedactor.redact(String(result.output.suffix(16_384))) }
            } catch { }
        }
        return .init(median: timings.sorted()[2], functions: functions, failed: false)
    }
}
