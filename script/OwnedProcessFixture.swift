import Foundation

/// Compile a test-owned native process so path-ownership probes see the owned
/// executable. Relocated Apple platform binaries may be killed by macOS before
/// the tested controller gets to signal them.
enum OwnedProcessFixture {
    enum Failure: Error { case compilerFailed(Int32) }

    static func makeSleeper(at executable: URL) throws {
        let source = executable.appendingPathExtension("c")
        try """
        #include <stdlib.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            unsigned seconds = argc > 1 ? (unsigned)strtoul(argv[1], 0, 10) : 20;
            sleep(seconds);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-o", executable.path]
        compiler.standardInput = FileHandle.nullDevice
        compiler.standardOutput = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw Failure.compilerFailed(compiler.terminationStatus) }
    }
}
