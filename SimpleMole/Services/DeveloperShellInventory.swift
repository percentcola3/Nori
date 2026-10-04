import Foundation
import Darwin

extension DeveloperShellService {
    struct Inventory: Equatable {
        let shellPath: String
        let kind: Kind
        let directory: String
        let names: [String]
        let profiles: [Profile]
        let loginFile: String?
        let usesCustomZdotdir: Bool
        let included: [IncludedFile]
    }

    struct IncludedFile: Identifiable, Equatable {
        let parentPath: String
        let lineNumber: Int
        let path: String
        let depth: Int
        let profile: Profile?
        let problem: Failure?
        var id: String { "\(parentPath):\(lineNumber):\(path)" }
    }

    static var defaultShellPath: String {
        guard let record = getpwuid(getuid()), let shell = record.pointee.pw_shell else { return "/bin/zsh" }
        return String(cString: shell)
    }

    /// Reads text only. A login shell and sourced scripts are never executed by inventory.
    static func inventory(home: String = NSHomeDirectory(), shellPath: String = defaultShellPath,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Inventory {
        let kind: Kind = shellPath.hasSuffix("/zsh") ? .zsh : shellPath.hasSuffix("/bash") ? .bash : .unsupported
        let names = kind == .bash ? bashFileNames : kind == .zsh ? fileNames : []
        let zdotdir = kind == .zsh ? staticZdotdir(home: home, environment: environment) : nil
        let directory = zdotdir ?? home
        let profiles = names.map { name -> Profile in
            do {
                let profileDirectory = kind == .zsh && name == ".zshenv" && environment["ZDOTDIR"] == nil ? home : directory
                var profile = try readProfile(name, home: profileDirectory)
                profile.homePath = home
                return profile
            } catch {
                return Profile(name: name, text: "", exists: true, variables: [],
                               problem: error as? Failure ?? .unreadable, originalData: Data(), identity: nil,
                               directoryPath: directory, homePath: home)
            }
        }
        let login = kind == .bash ? bashFileNames.prefix(3).first { name in profiles.contains { $0.name == name && $0.exists } } : nil
        return Inventory(shellPath: shellPath, kind: kind, directory: directory, names: names, profiles: profiles,
                         loginFile: login, usesCustomZdotdir: directory != home,
                         included: includedFiles(in: profiles, home: home, zdotdir: directory))
    }

    static func startupNames(in profiles: [Profile]) -> [String] {
        guard profiles.contains(where: { bashFileNames.contains($0.name) }) else { return fileNames }
        let login = bashFileNames.prefix(3).first { name in profiles.contains { $0.name == name && $0.exists } }
        // bashrc is not loaded by an interactive login bash unless explicitly sourced.
        return login.map { [$0] } ?? []
    }

    private static func staticZdotdir(home: String, environment: [String: String]) -> String? {
        if let path = environment["ZDOTDIR"], path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        guard let profile = try? readProfile(".zshenv", home: home) else { return nil }
        var result: String?
        var context = DeclarationContext()
        for line in profile.text.components(separatedBy: "\n") {
            if context.consumeHeredoc(line) { continue }
            let accepts = context.acceptsDeclaration
            context.consumeShellLine(line)
            guard accepts, let range = line.range(of: #"^\s*(?:export\s+)?ZDOTDIR="#, options: .regularExpression),
                  let parsed = structuredValue(String(line[range.upperBound...])),
                  let value = expand(parsed.parts, environment: ["HOME": home]), value.hasPrefix("/") else { continue }
            result = URL(fileURLWithPath: value).standardizedFileURL.path
        }
        return result
    }

    static func includedFiles(in profiles: [Profile], home: String = NSHomeDirectory(),
                              zdotdir: String? = nil, maximumDepth: Int = 3, maximumFiles: Int = 32) -> [IncludedFile] {
        var result: [IncludedFile] = []
        var visited = Set<String>()
        let variables = ["HOME": home, "ZDOTDIR": zdotdir ?? home]
        func walk(_ profile: Profile, depth: Int) {
            guard depth < maximumDepth, result.count < maximumFiles else { return }
            visited.insert(URL(fileURLWithPath: profile.path).standardizedFileURL.path)
            var context = DeclarationContext()
            for (index, line) in profile.text.components(separatedBy: "\n").enumerated() {
                if context.consumeHeredoc(line) { continue }
                let accepts = context.acceptsDeclaration
                context.consumeShellLine(line)
                guard accepts, result.count < maximumFiles,
                      let range = line.range(of: #"^\s*(?:source|\.)\s+"#, options: .regularExpression),
                      let parsed = structuredValue(String(line[range.upperBound...])),
                      let path = expand(parsed.parts, environment: variables), path.hasPrefix("/") else { continue }
                let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
                guard visited.insert(normalized).inserted else { continue }
                let read = Result { try readSourceProfile(path: normalized) }
                let included: Profile?
                let problem: Failure?
                switch read {
                case .success(let profile): included = profile; problem = nil
                case .failure(let error): included = nil; problem = error as? Failure ?? .unreadable
                }
                result.append(.init(parentPath: profile.path, lineNumber: index + 1, path: normalized,
                                    depth: depth + 1, profile: included, problem: problem))
                if let included { walk(included, depth: depth + 1) }
            }
        }
        for profile in profiles { walk(profile, depth: 0) }
        return result
    }
}
