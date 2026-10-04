import Foundation

struct DeveloperPackage: Identifiable, Equatable, Sendable {
    let manager: String
    let name: String
    let version: String
    let available: String?
    var id: String { manager + ":" + name }
}

struct DeveloperBrewService: Identifiable, Equatable, Sendable {
    let name: String
    let status: String
    let user: String
    let file: String
    var pid: Int32? = nil
    var logPaths: [String] = []
    var exitCode: Int? = nil
    var id: String { name }
    var defaultPort: String? {
        switch name.components(separatedBy: "@").first {
        case "postgresql": return "5432"
        case "mysql", "mariadb": return "3306"
        case "redis": return "6379"
        case "mongodb-community": return "27017"
        default: return nil
        }
    }
}

enum DeveloperPackageService {
    struct Inventory: Sendable {
        var packages: [DeveloperPackage] = []
        var services: [DeveloperBrewService] = []
        var failures: [String] = []
    }

    static func validName(_ name: String) -> Bool {
        name.range(of: #"^(?:@[A-Za-z0-9_.-]+/)?[A-Za-z0-9][A-Za-z0-9_.+-]{0,127}$"#, options: .regularExpression) != nil
    }

    static func scan(environment: [String: String], checkUpdates: Bool = false) async -> Inventory {
        var inventory = Inventory()
        var env = environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["NO_COLOR"] = "1"
        env["COREPACK_ENABLE_NETWORK"] = "0"
        env["RUSTUP_AUTO_INSTALL"] = "0"
        env["GOTOOLCHAIN"] = "local"
        env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        env["DOTNET_SKIP_FIRST_TIME_EXPERIENCE"] = "1"
        let probes: [(String, [String])] = [("brew", ["list", "--versions"]), ("brew", ["list", "--cask", "--versions"]),
            ("npm", ["ls", "-g", "--depth=0", "--json"]), ("pnpm", ["ls", "-g", "--depth=0", "--json"]),
            ("pipx", ["list", "--json"]), ("cargo", ["install", "--list"]), ("dotnet", ["tool", "list", "--global"])]
        for (manager, args) in probes {
            guard !Task.isCancelled else { break }
            guard let path = DeveloperToolchainService.executable(manager, environment: env) else { continue }
            let result = await MoleEngine().run(executable: URL(fileURLWithPath: path), arguments: args, environment: env, timeout: 20)
            if result.timedOut || (!result.succeeded && !["npm", "pnpm"].contains(manager)) { inventory.failures.append(manager); continue }
            inventory.packages += parsePackages(manager: manager == "brew" && args.contains("--cask") ? "brew-cask" : manager, output: result.output)
        }
        if let brew = DeveloperToolchainService.executable("brew", environment: env), !Task.isCancelled {
            let result = await MoleEngine().run(executable: URL(fileURLWithPath: brew), arguments: ["services", "info", "--all", "--json"], environment: env, timeout: 20)
            if result.succeeded { inventory.services = parseServices(result.output) }
            else {
                let fallback = await MoleEngine().run(executable: URL(fileURLWithPath: brew), arguments: ["services", "list", "--json"], environment: env, timeout: 20)
                inventory.services = parseServices(fallback.output)
                if !fallback.succeeded { inventory.failures.append("brew services") }
            }
            if checkUpdates {
                let outdated = await MoleEngine().run(executable: URL(fileURLWithPath: brew), arguments: ["outdated", "--json=v2"], environment: env, timeout: 60)
                if let data = outdated.output.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    var updates: [String: String] = [:]
                    for key in ["formulae", "casks"] {
                        for entry in json[key] as? [[String: Any]] ?? [] {
                            if let name = entry["name"] as? String {
                                updates[(key == "casks" ? "brew-cask:" : "brew:") + name] = (entry["current_version"] as? String) ?? (entry["latest_version"] as? String) ?? ""
                            }
                        }
                    }
                    inventory.packages = inventory.packages.map { item in
                        .init(manager: item.manager, name: item.name, version: item.version, available: updates[item.id])
                    }
                } else if !outdated.succeeded { inventory.failures.append("brew") }
            }
        }
        if checkUpdates {
            for manager in ["npm", "pnpm"] {
                guard let path = DeveloperToolchainService.executable(manager, environment: env), !Task.isCancelled else { continue }
                let result = await MoleEngine().run(executable: URL(fileURLWithPath: path), arguments: ["outdated", "-g", "--json"], environment: env, timeout: 60)
                guard let data = result.output.data(using: .utf8), let entries = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { continue }
                inventory.packages = inventory.packages.map { item in
                    .init(manager: item.manager, name: item.name, version: item.version,
                          available: item.manager == manager ? entries[item.name]?["latest"] as? String : item.available)
                }
            }
        }
        return inventory
    }

    static func parsePackages(manager: String, output: String) -> [DeveloperPackage] {
        if ["npm", "pnpm", "pipx"].contains(manager), let data = output.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) {
            let roots = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] } ?? []
            if manager == "pipx" {
                let root = roots.first ?? [:]
                return (root["venvs"] as? [String: [String: Any]] ?? [:]).compactMap { name, value in
                    let metadata = value["metadata"] as? [String: Any]
                    let package = metadata?["main_package"] as? [String: Any]
                    return validName(name) ? .init(manager: manager, name: name, version: package?["package_version"] as? String ?? "", available: nil) : nil
                }.sorted { $0.name < $1.name }
            }
            let packages: [DeveloperPackage] = roots.flatMap { root -> [DeveloperPackage] in (root["dependencies"] as? [String: [String: Any]] ?? [:]).compactMap { name, value -> DeveloperPackage? in
                validName(name) ? .init(manager: manager, name: name, version: value["version"] as? String ?? "", available: nil) : nil
            } }
            var seen: Set<String> = []
            return packages.filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
        }
        return output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, validName(String(fields[0])) else { return nil }
            if manager == "cargo" {
                guard !line.hasPrefix(" "), fields[1].hasPrefix("v") else { return nil }
            } else if manager == "dotnet" {
                guard fields[1].first?.isNumber == true else { return nil }
            }
            return .init(manager: manager, name: String(fields[0]), version: String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "v:")), available: nil)
        }
    }

    static func parseServices(_ output: String) -> [DeveloperBrewService] {
        guard let data = output.data(using: .utf8), let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return entries.compactMap { item in
            guard let name = item["name"] as? String, validName(name) else { return nil }
            let number = (item["pid"] as? NSNumber)?.int64Value
            let pid = number.flatMap { $0 > 0 && $0 <= Int32.max ? Int32($0) : nil }
            let paths = ["log_path", "error_log_path"].compactMap { item[$0] as? String }.filter { $0.hasPrefix("/") && !$0.contains("\0") }
            return .init(name: name, status: item["status"] as? String ?? "unknown", user: item["user"] as? String ?? "", file: item["file"] as? String ?? "",
                         pid: pid, logPaths: Array(Set(paths)).sorted(), exitCode: (item["exit_code"] as? NSNumber)?.intValue)
        }
    }

    static func command(_ operation: String, manager: String = "brew", name: String = "", environment: [String: String]) -> DeveloperCommand? {
        guard name.isEmpty || validName(name) else { return nil }
        let executableName = manager == "brew-cask" ? "brew" : manager
        guard let executable = DeveloperToolchainService.executable(executableName, environment: environment) else { return nil }
        var arguments: [String]
        switch (manager, operation) {
        case ("brew", "update"): arguments = ["update"]
        case ("brew", "doctor"): arguments = ["doctor"]
        case ("brew", "autoremovePreview"): arguments = ["autoremove", "--dry-run"]
        case ("brew", "autoremove"): arguments = ["autoremove"]
        case ("brew", "upgradeAll"): arguments = ["upgrade"]
        case ("brew", "upgrade"): arguments = ["upgrade", name]
        case ("brew-cask", "upgrade"): arguments = ["upgrade", "--cask", name]
        case ("brew", "uninstall"): arguments = ["uninstall", name]
        case ("brew-cask", "uninstall"): arguments = ["uninstall", "--cask", name]
        case ("brew", "start"), ("brew", "stop"), ("brew", "restart"): arguments = ["services", operation, name]
        case ("npm", "upgrade"), ("pnpm", "upgrade"): arguments = ["update", "-g", name]
        case ("npm", "uninstall"), ("pnpm", "uninstall"): arguments = ["uninstall", "-g", name]
        case ("pipx", "upgrade"), ("pipx", "uninstall"): arguments = [operation, name]
        case ("cargo", "upgrade"): arguments = ["install", name, "--force"]
        case ("cargo", "uninstall"): arguments = ["uninstall", name]
        case ("dotnet", "upgrade"): arguments = ["tool", "update", "--global", name]
        case ("dotnet", "uninstall"): arguments = ["tool", "uninstall", "--global", name]
        default: return nil
        }
        if ["upgrade", "uninstall", "start", "stop", "restart"].contains(operation), name.isEmpty { return nil }
        var env = environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["NO_COLOR"] = "1"
        return .init(titleKey: "dev.package." + operation, executable: executable, arguments: arguments, environment: env, timeout: 1800, privilegedArguments: nil)
    }
}
