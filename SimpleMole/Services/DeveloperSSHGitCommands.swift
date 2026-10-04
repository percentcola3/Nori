import Foundation
import CryptoKit
import Darwin

extension DeveloperSSHGitService {
    enum GitField: String, CaseIterable { case name = "user.name", email = "user.email" }
    static let gitReadKeys = ["user.name", "user.email", "credential.helper", "commit.gpgsign", "gpg.format", "user.signingkey"]
    static func commandEnvironment(_ sampled: [String: String], home: String = NSHomeDirectory()) -> [String: String] {
        var environment = sampled
        environment["HOME"] = home
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        return environment
    }
    static func gitCommand(field: GitField, value: String, environment: [String: String], home: String = NSHomeDirectory()) -> DeveloperCommand? {
        guard validIdentity(value), let git = DeveloperToolchainService.executable("git", environment: environment) else { return nil }
        return .init(titleKey: "dev.sshgit.saveIdentity", executable: git,
                     arguments: ["config", "--global", "--replace-all", "--", field.rawValue, value],
                     environment: commandEnvironment(environment, home: home), timeout: 10, privilegedArguments: nil)
    }
    static func validIdentity(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 254 && !value.contains("\n") && !value.contains("\r") && !value.contains("\0") }
    static func connectionCommand(host: String, environment: [String: String], home: String = NSHomeDirectory()) -> DeveloperCommand? {
        guard ["github.com", "gitlab.com", "gitee.com"].contains(host) else { return nil }
        return .init(titleKey: "dev.sshgit.testConnection", executable: "/usr/bin/ssh",
                     arguments: ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                                 "-o", "UserKnownHostsFile=" + home + "/.ssh/known_hosts", "-o", "GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts",
                                 "-o", "UpdateHostKeys=no", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ForwardAgent=no",
                                 "-o", "ClearAllForwardings=yes", "-T", "git@" + host],
                     environment: commandEnvironment(environment, home: home), timeout: 12, privilegedArguments: nil)
    }
    static func hostConnectionCommand(_ block: HostBlock, environment: [String: String], home: String = NSHomeDirectory(), knownKeys: [Key]? = nil) -> DeveloperCommand? {
        guard block.isEditable, block.fields["user"] == "git", block.fields["proxyjump"] == nil,
              block.fields["port"] == nil || block.fields["port"] == "22", let hostname = block.fields["hostname"],
              let identity = block.fields["identityfile"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
              let base = connectionCommand(host: hostname, environment: environment, home: home) else { return nil }
        let path = identity.hasPrefix("~/") ? home + String(identity.dropFirst()) : identity
        guard (knownKeys ?? keys(home: home)).contains(where: { $0.privatePath == path }) else { return nil }
        var arguments = base.arguments
        arguments.insert(contentsOf: ["-i", path, "-o", "IdentitiesOnly=yes"], at: arguments.count - 2)
        return .init(titleKey: base.titleKey, executable: base.executable, arguments: arguments, environment: base.environment,
                     timeout: base.timeout, privilegedArguments: nil)
    }
    static func keyGenerationScript(name: String, comment: String, home: String = NSHomeDirectory()) -> String? {
        guard validName(name), validIdentity(comment), !FileManager.default.fileExists(atPath: home + "/.ssh/" + name) else { return nil }
        let path = home + "/.ssh/" + name
        let quote = DeveloperCLIService.shellQuote
        return "#!/bin/zsh -f\nset -e\numask 077\n[[ ! -L " + quote(home + "/.ssh") + " ]] || exit 1\n/bin/mkdir -p " + quote(home + "/.ssh")
            + "\n[[ ! -e " + quote(path) + " && ! -L " + quote(path) + " ]] || exit 1\nexec /usr/bin/ssh-keygen -t ed25519 -C " + quote(comment) + " -f " + quote(path) + "\n"
    }
    static func trustConnectionScript(host: String, home: String = NSHomeDirectory()) -> String? {
        guard ["github.com", "gitlab.com", "gitee.com"].contains(host) else { return nil }
        let quote = DeveloperCLIService.shellQuote
        let arguments = ["/usr/bin/ssh", "-F", "/dev/null", "-o", "StrictHostKeyChecking=ask", "-o", "UpdateHostKeys=no",
                         "-o", "UserKnownHostsFile=" + home + "/.ssh/known_hosts", "-o", "ForwardAgent=no",
                         "-o", "ClearAllForwardings=yes", "-o", "ConnectTimeout=8", "-T", "git@" + host]
        return "#!/bin/zsh -f\n[[ ! -L " + quote(home + "/.ssh") + " && ! -L " + quote(home + "/.ssh/known_hosts")
            + " ]] || exit 1\nexec " + arguments.map(quote).joined(separator: " ") + "\n"
    }

    static func connectionSucceeded(output: String, exitCode: Int32) -> Bool {
        guard exitCode == 0 || exitCode == 1 else { return false }
        let lowered = output.lowercased()
        return lowered.contains("successfully authenticated") || lowered.contains("welcome to gitlab") || lowered.contains("successfully authenticated, but gitee")
    }
    static func directoryIdentityCommands(directory: String, name: String, email: String, environment: [String: String],
                                           home: String = NSHomeDirectory(), identifier: String = UUID().uuidString) -> [DeveloperCommand]? {
        guard directory.hasPrefix("/"), !directory.contains("\n"), !directory.contains("\0"), !directory.contains("\r"),
              !directory.contains("*"), !directory.contains("?"), !directory.contains("["),
              validIdentity(name), validIdentity(email), validName(identifier),
              let git = DeveloperToolchainService.executable("git", environment: environment) else { return nil }
        let normalized = URL(fileURLWithPath: directory).standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = home + "/Library/Application Support/Nori/GitIdentities/" + identifier + ".gitconfig"
        let arguments = [["config", "--file", path, "--replace-all", "--", "user.name", name],
                         ["config", "--file", path, "--replace-all", "--", "user.email", email],
                         ["config", "--global", "--replace-all", "--", "includeIf.gitdir:/" + normalized + "/.path", path]]
        let group = UUID()
        return arguments.map {
            var command = DeveloperCommand(titleKey: "dev.sshgit.directoryIdentity", executable: git, arguments: $0,
                                           environment: commandEnvironment(environment, home: home), timeout: 10, privilegedArguments: nil)
            command.operationGroup = group
            return command
        }
    }
    static func prepareIdentityDirectory(home: String = NSHomeDirectory()) throws {
        var descriptor = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unsafe }
        defer { close(descriptor) }
        for (index, component) in ["Library", "Application Support", "Nori", "GitIdentities"].enumerated() {
            if mkdirat(descriptor, component, 0o700) != 0, errno != EEXIST { throw Failure.write }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw Failure.unsafe }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == getuid() else { close(next); throw Failure.unsafe }
            if index >= 2, fchmod(next, 0o700) != 0 { close(next); throw Failure.write }
            close(descriptor); descriptor = next
        }
    }

    static func createIdentityFile(_ path: String, home: String = NSHomeDirectory()) throws {
        let parent = home + "/Library/Application Support/Nori/GitIdentities"
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().path == parent, validName(url.lastPathComponent), url.lastPathComponent.hasSuffix(".gitconfig") else { throw Failure.unsafe }
        try prepareIdentityDirectory(home: home)
        let directory = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw Failure.unsafe }; defer { close(directory) }
        let file = openat(directory, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw Failure.unsafe }; defer { close(file) }
        guard fsync(file) == 0 else { throw Failure.write }; _ = fsync(directory)
    }
}
