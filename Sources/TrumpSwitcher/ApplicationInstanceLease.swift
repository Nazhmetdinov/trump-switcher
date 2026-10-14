import Foundation
import Darwin

/// A kernel lock shared by installed/development copies; exit or crash releases it.
final class ApplicationInstanceLease {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    static func acquire(in directory: URL) throws -> ApplicationInstanceLease? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("instance.lock").path
        let descriptor = path.withCString { open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            close(descriptor); throw CocoaError(.fileReadNoPermission)
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let reason = errno; close(descriptor)
            if reason == EWOULDBLOCK || reason == EAGAIN { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(reason))
        }
        return ApplicationInstanceLease(descriptor)
    }
    deinit { close(descriptor) }
}
