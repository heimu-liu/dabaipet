import DabaiPetCore
import Darwin
import Foundation

/// A kernel-held lock for normal launches of a bundle within this user's account.
final class PetInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    static func acquire() throws -> PetInstanceLock? {
        let identifier = Bundle.main.bundleIdentifier ?? DabaiPetIdentity.bundleIdentifier
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let path = support.appendingPathComponent("\(identifier).instance.lock", isDirectory: false).path
        let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        var descriptor: Int32
        repeat {
            descriptor = open(path, flags, mode_t(S_IRUSR | S_IWUSR))
        } while descriptor == -1 && errno == EINTR
        guard descriptor != -1 else { throw posixError(errno) }

        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw posixError(errno) }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid() else {
                throw POSIXError(.EACCES)
            }

            var result: Int32
            repeat {
                result = flock(descriptor, LOCK_EX | LOCK_NB)
            } while result == -1 && errno == EINTR
            if result == 0 { return PetInstanceLock(descriptor: descriptor) }
            let code = errno
            if code != EWOULDBLOCK { throw posixError(code) }
        } catch {
            close(descriptor)
            throw error
        }
        close(descriptor)
        return nil
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
