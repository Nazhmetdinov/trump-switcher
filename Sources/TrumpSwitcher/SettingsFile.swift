import Foundation
import Darwin
import SwitcherCore

/// Import a bounded regular local file, including if it grows during the read.
enum SettingsFile {
    static let maximumBytes = 1_048_576
    static func read(_ url: URL) throws -> CorrectionSettings {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        // Validate the opened descriptor, not metadata of a path that can be
        // swapped before open. NONBLOCK also prevents a substituted FIFO from
        // hanging the settings window; NOFOLLOW rejects final-component links.
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor); throw CocoaError(.fileReadUnknown)
        }
        guard info.st_size >= 0, info.st_size <= maximumBytes else {
            close(descriptor); throw CocoaError(.fileReadTooLarge)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        guard let settings = CorrectionSettings.decode(data) else { throw CocoaError(.coderInvalidValue) }
        return settings
    }
}
