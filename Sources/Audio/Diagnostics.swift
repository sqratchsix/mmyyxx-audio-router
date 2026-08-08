import Foundation
import os

/// Startup and device-change logging. Goes to both stderr (visible when the
/// binary is launched from a terminal) and the unified log, so
/// `log stream --predicate 'subsystem == "com.jaredsimon.mmyyxx"'`
/// works when the app was launched from Finder.
///
/// Nothing here is safe to call from the render thread.
enum Diagnostics {
    private static let logger = Logger(subsystem: "com.jaredsimon.mmyyxx", category: "engine")

    static func log(_ message: String) {
        FileHandle.standardError.write(Data(("[mmyyxx] " + message + "\n").utf8))
        logger.log("\(message, privacy: .public)")
    }
}
