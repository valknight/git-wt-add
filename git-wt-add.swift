// git-wt-add: create a git worktree seeded from a source worktree but much much faster. tries to use APFS's clonefile where possible

import CryptoKit
import Foundation
import Synchronization

// MARK: - Consts

let logPrefix = "git-wt-add: "
/// --copy .venv is built with uv instead of cloned.
let venvDir = ".venv"
let gitlinkMode: UInt32 = 0o160000

let usage = """
Usage: git-wt-add PATH REF [-b NEWBRANCH] [--source DIR] [--copy REL]...

Creates a git worktree at PATH checked out at REF using APFS copy-on-write
clones.

  PATH           new worktree path
  REF            branch, tag or commit to check out
  -b NEWBRANCH   auto create NEWBRANCH at REF (passed to git worktree add -b)
  --source DIR   source worktree to clone from
                 (default: main worktree of the current repo)
  --copy REL     also clone REL. this is a path relative to the repo root.
                 e.g. pass `.cache` to also quick-copy some generated cache.
  -h, --help     show this help
"""

// MARK: - Output

func writeFD(_ fh: FileHandle, _ s: String) { try? fh.write(contentsOf: Data(s.utf8)) }

/// write unbuffers to make sure we interleave correctly with git
func say(_ msg: String) { writeFD(.standardOutput, "\(logPrefix)\(msg)\n") }
func sayErr(_ msg: String) { writeFD(.standardError, "\(logPrefix)\(msg)\n") }

struct Fail: Error { let code: Int32 }

func die(_ msg: String) -> Fail {
    sayErr(msg)
    return Fail(code: 1)
}

func errText(_ e: Int32) -> String { String(cString: strerror(e)) }

func errText(_ error: any Error) -> String {
    var e = error as NSError
    while e.domain != NSPOSIXErrorDomain, let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { e = u }
    return e.domain == NSPOSIXErrorDomain ? errText(Int32(e.code)) : e.localizedDescription
}

// MARK: - Signals

let interruptedBy = Atomic<Int32>(0)
/// used to terminate children, we need to forward SIGINTs on
let runningChild = Atomic<Int32>(0)

/// and actually make sure we kill children
func installSignalHandlers() {
    for sig in [SIGHUP, SIGINT, SIGTERM] {
        _ = signal(sig) { s in
            interruptedBy.store(s, ordering: .relaxed)
            let pid = runningChild.load(ordering: .relaxed)
            if pid > 0 { kill(pid, s) }
        }
    }
    _ = signal(SIGPIPE, SIG_IGN)
}

func checkInterrupted() throws(Fail) {
    let s = interruptedBy.load(ordering: .relaxed)
    if s != 0 { throw Fail(code: 128 + s) }
}

// MARK: - Filesystem helpers
// some little helpers to make calls to fm easier to read

nonisolated var fm: FileManager { .default }


func isDir(_ p: String) -> Bool {
    var d: ObjCBool = false
    return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue
}
func isRegularFile(_ p: String) -> Bool {
    var d: ObjCBool = false
    return fm.fileExists(atPath: p, isDirectory: &d) && !d.boolValue
}
func existsOrLink(_ p: String) -> Bool { (try? fm.attributesOfItem(atPath: p)) != nil }

func removeTree(_ path: String) { try? fm.removeItem(atPath: path) }

func realPath(_ p: String) -> String? {
    guard let r = realpath(p, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
}

/// Falls back to a full copy where clonefile can't (another volume, no APFS).
func cloneFile(_ src: String, _ dst: String) -> Int32 {
    if clonefile(src, dst, UInt32(CLONE_NOFOLLOW)) == 0 { return 0 }
    let e = errno
    guard e == EXDEV || e == ENOTSUP else { return e }
    let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW)
    return copyfile(src, dst, nil, flags) == 0 ? 0 : errno
}

func dirname(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
func basename(_ p: String) -> String { (p as NSString).lastPathComponent }

/// try to prefer $PWD to currentDirectoryPath, just incase of symlinking nonsense
func currentDir() -> String {
    func fileID(_ p: String) -> NSObject? {
        (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
    }
    if let pwd = ProcessInfo.processInfo.environment["PWD"], pwd.hasPrefix("/"),
       let id = fileID(pwd), id == fileID(".") {
        return pwd
    }
    return fm.currentDirectoryPath
}

func lines(_ data: Data) -> [String] {
    var s = String(decoding: data, as: UTF8.self)
    while s.hasSuffix("\n") { s.removeLast() }
    return s.isEmpty ? [] : s.components(separatedBy: "\n")
}

func stripOneSlash(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }

func which(_ name: String) -> String? {
    if name.contains("/") { return name }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return path.split(separator: ":").map { "\($0)/\(name)" }
        .first { fm.isExecutableFile(atPath: $0) && !isDir($0) }
}

// MARK: - Processes

struct ProcResult {
    let status: Int32   // exit code, or 128+signal
    let out: Data
}

enum Stdio { case inherit, capture, null }

/// this is a fast way to spawn a process
/// swift's Process.waitUntilExit polls the run loop and adds ~45ms to every git call.
func run(_ argv: [String], stdout: Stdio = .inherit, stderr: Stdio = .inherit,
         input: Data? = nil, env: [String: String?] = [:]) throws(Fail) -> ProcResult {
    guard let exe = which(argv[0]) else {
        sayErr("\(argv[0]): \(errText(ENOENT))")
        throw Fail(code: 127)
    }
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    defer { posix_spawn_file_actions_destroy(&fa) }
    var outPipe: [Int32] = [-1, -1], inPipe: [Int32] = [-1, -1]
    if input != nil {
        guard pipe(&inPipe) == 0 else { throw die("pipe: \(errText(errno))") }
        posix_spawn_file_actions_adddup2(&fa, inPipe[0], 0)
    } else {
        posix_spawn_file_actions_addinherit_np(&fa, 0)
    }
    switch stdout {
    case .capture:
        guard pipe(&outPipe) == 0 else { throw die("pipe: \(errText(errno))") }
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
    case .null: posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
    case .inherit: posix_spawn_file_actions_addinherit_np(&fa, 1)
    }
    if stderr == .null {
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
    } else {
        posix_spawn_file_actions_addinherit_np(&fa, 2)
    }
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
                                          | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    posix_spawnattr_setpgroup(&attr, 0)
    var sigs = sigset_t()
    sigemptyset(&sigs)
    posix_spawnattr_setsigmask(&attr, &sigs)
    sigaddset(&sigs, SIGPIPE)
    posix_spawnattr_setsigdefault(&attr, &sigs)

    var envp = ProcessInfo.processInfo.environment
    for (k, v) in env { envp[k] = v }
    let cArgs = argv.map { strdup($0) } + [nil]
    let cEnv = envp.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (cArgs + cEnv).forEach { free($0) } }
    var pid: pid_t = 0
    let e = posix_spawn(&pid, exe, &fa, &attr, cArgs, cEnv)
    for fd in [inPipe[0], outPipe[1]] where fd >= 0 { close(fd) }
    if e != 0 {
        for fd in [inPipe[1], outPipe[0]] where fd >= 0 { close(fd) }
        sayErr("\(argv[0]): \(errText(e))")
        throw Fail(code: 127)
    }
    runningChild.store(pid, ordering: .relaxed)
    defer { runningChild.store(0, ordering: .relaxed) }
    if let input {
        let h = FileHandle(fileDescriptor: inPipe[1], closeOnDealloc: true)
        try? h.write(contentsOf: input)
        try? h.close()
    }
    let out = stdout == .capture
        ? FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true).readDataToEndOfFile() : Data()
    var st: Int32 = 0
    while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
    // WIFEXITED / WEXITSTATUS / WTERMSIG
    return ProcResult(status: st & 0x7f == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f), out: out)
}

@discardableResult
func check(_ r: ProcResult) throws(Fail) -> ProcResult {
    if r.status != 0 { throw Fail(code: r.status) }
    return r
}

// MARK: - Timing

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func fmtSecs(_ ns: UInt64) -> String {
    let ms = ns / 1_000_000
    return String(format: "%llu.%03llus", ms / 1000, ms % 1000)
}

final class Timings {
    private var last = nowNs()
    let start = nowNs()
    private(set) var phases: [(String, UInt64)] = []
    func mark(_ name: String) {
        let t = nowNs()
        phases.append((name, t - last))
        last = t
    }
    var line: String {
        (phases.map { "\($0.0) \(fmtSecs($0.1))" } + ["total \(fmtSecs(nowNs() - start))"])
            .joined(separator: ", ")
    }
}

// MARK: - Clone

struct CloneJob: Sendable {
    let src: String
    let dst: String
}

func runCloneJobs(_ jobs: [CloneJob]) -> (job: CloneJob, err: Int32)? {
    if jobs.isEmpty { return nil }
    let workers = min(max(1, ProcessInfo.processInfo.activeProcessorCount), jobs.count)
    let next = Atomic<Int>(0)
    let failedAt = Atomic<Int>(-1)
    let failErrno = Atomic<Int32>(0)
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
        while failedAt.load(ordering: .relaxed) < 0 && interruptedBy.load(ordering: .relaxed) == 0 {
            let i = next.wrappingAdd(1, ordering: .relaxed).oldValue
            if i >= jobs.count { break }
            let e = cloneFile(jobs[i].src, jobs[i].dst)
            if e != 0 && failedAt.compareExchange(expected: -1, desired: i, ordering: .relaxed).exchanged {
                failErrno.store(e, ordering: .relaxed)
            }
        }
    }
    // concurrentPerform has joined all workers, so these loads see their stores.
    let i = failedAt.load(ordering: .relaxed)
    return i < 0 ? nil : (jobs[i], failErrno.load(ordering: .relaxed))
}

func relPath(_ p: String, under root: String) -> String {
    p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p
}

// MARK: - Index

/// entry of `git ls-files -s -z`
struct IndexEntry {
    let mode: UInt32
    let oid: [UInt8]
    let path: [UInt8]
    var name: String { String(decoding: path, as: UTF8.self) }
}

/// source index recorded for a path
struct StatClaim {
    let entry: IndexEntry
    let ctime: (sec: UInt32, nsec: UInt32)
    let mtime: (sec: UInt32, nsec: UInt32)
    let ino: UInt32
    let size: UInt32
}

/// reads `git ls-files` output in place, but about 10x faster than scanning output directly from git
struct Scanner {
    let b: [UInt8]
    var i = 0
    var atEnd: Bool { i >= b.count }

    static func digit(_ c: UInt8) -> UInt32 {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(c - UInt8(ascii: "a") + 10)
        default: 99
        }
    }

    /// Digits up to `end`, which is skipped.
    mutating func number(radix: UInt32 = 10, _ end: Character) -> UInt32? {
        let stop = end.asciiValue!
        var v: UInt32 = 0
        let start = i
        while i < b.count, b[i] != stop {
            let d = Self.digit(b[i])
            guard d < radix else { return nil }
            v = v &* radix &+ d
            i += 1
        }
        guard i > start, i < b.count else { return nil }
        i += 1
        return v
    }

    /// Hex up to `end`, which is skipped.
    mutating func hex(_ end: Character) -> [UInt8]? {
        let stop = end.asciiValue!
        var out: [UInt8] = []
        out.reserveCapacity(32)
        while i + 1 < b.count, b[i] != stop {
            let hi = Self.digit(b[i]), lo = Self.digit(b[i + 1])
            guard hi < 16, lo < 16 else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        guard !out.isEmpty, i < b.count else { return nil }
        i += 1
        return out
    }

    mutating func literal(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard i + u.count <= b.count, b[i..<(i + u.count)].elementsEqual(u) else { return false }
        i += u.count
        return true
    }

    /// "MODE OID STAGE\tPATH\0"
    mutating func entry() -> (entry: IndexEntry, stage: UInt32)? {
        guard let mode = number(radix: 8, " "), let oid = hex(" "), let stage = number("\t"),
              let nul = b[i...].firstIndex(of: 0) else { return nil }
        defer { i = nul + 1 }
        return (IndexEntry(mode: mode, oid: oid, path: Array(b[i..<nul])), stage)
    }
}

func parseEntries(_ data: Data) -> [IndexEntry]? {
    var sc = Scanner(b: [UInt8](data))
    var out: [IndexEntry] = []
    while !sc.atEnd {
        guard let (e, _) = sc.entry() else { return nil }
        out.append(e)
    }
    return out
}

func parseStatClaims(_ data: Data) -> [StatClaim]? {
    var sc = Scanner(b: [UInt8](data))
    var out: [StatClaim] = []
    while !sc.atEnd {
        guard let (e, stage) = sc.entry(),
              sc.literal("  ctime: "), let cs = sc.number(":"), let cn = sc.number("\n"),
              sc.literal("  mtime: "), let ms = sc.number(":"), let mn = sc.number("\n"),
              sc.literal("  dev: "), sc.number("\t") != nil, sc.literal("ino: "), let ino = sc.number("\n"),
              sc.literal("  uid: "), sc.number("\t") != nil, sc.literal("gid: "), sc.number("\n") != nil,
              sc.literal("  size: "), let size = sc.number("\t"), sc.literal("flags: "),
              let flags = sc.number(radix: 16, "\n") else { return nil }
        // Assume-unchanged (0x8000), intent-to-add (1<<29) and skip-worktree
        // (1<<30) entries prove nothing about the file; nor do conflicts.
        if stage == 0 && flags & 0x6000_8000 == 0 {
            out.append(StatClaim(entry: e, ctime: (cs, cn), mtime: (ms, mn), ino: ino, size: size))
        }
    }
    return out
}

func matchClaims(_ entries: [IndexEntry], _ claims: [StatClaim]) -> [Int] {
    var out = [Int](repeating: -1, count: entries.count)
    var j = 0
    for (k, e) in entries.enumerated() {
        while j < claims.count && claims[j].entry.path.lexicographicallyPrecedes(e.path) { j += 1 }
        if j < claims.count && claims[j].entry.path == e.path { out[k] = j }
    }
    return out
}

func u32<T: BinaryInteger>(_ v: T) -> UInt32 { UInt32(truncatingIfNeeded: v) }

struct FileStat {
    var ctime = timespec(), mtime = timespec()
    var dev: UInt32 = 0, ino: UInt64 = 0, mode: UInt32 = 0, uid: UInt32 = 0, gid: UInt32 = 0
    var size: Int64 = 0

    init() {}
    init(_ st: stat) {
        ctime = st.st_ctimespec; mtime = st.st_mtimespec
        dev = u32(st.st_dev); ino = st.st_ino; mode = UInt32(st.st_mode)
        uid = st.st_uid; gid = st.st_gid; size = st.st_size
    }
    var type: UInt32 { mode & UInt32(S_IFMT) }
}

func dirStats(_ dir: String) -> [[UInt8]: FileStat]? {
    let fd = open(dir, O_RDONLY | O_DIRECTORY)
    if fd < 0 { return nil }
    defer { close(fd) }
    var al = attrlist()
    al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    // The buffer holds these in bit order, after the returned set.
    let common: [attrgroup_t] = [attrgroup_t(ATTR_CMN_RETURNED_ATTRS), attrgroup_t(ATTR_CMN_NAME),
                                 attrgroup_t(ATTR_CMN_DEVID), attrgroup_t(ATTR_CMN_OBJTYPE),
                                 attrgroup_t(ATTR_CMN_MODTIME), attrgroup_t(ATTR_CMN_CHGTIME),
                                 attrgroup_t(ATTR_CMN_OWNERID), attrgroup_t(ATTR_CMN_GRPID),
                                 attrgroup_t(ATTR_CMN_ACCESSMASK), attrgroup_t(ATTR_CMN_FILEID)]
    al.commonattr = common.reduce(0, |)
    al.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
    let size = 128 * 1024
    let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    defer { buf.deallocate() }
    var out: [[UInt8]: FileStat] = [:]
    while true {
        // FSOPT_PACK_INVAL_ATTRS: every attribute has its slot, valid or not.
        let n = getattrlistbulk(fd, &al, buf, size, UInt64(FSOPT_PACK_INVAL_ATTRS))
        if n < 0 { return nil }
        if n == 0 { break }
        var entry = UnsafeRawPointer(buf)
        for _ in 0..<n {
            var p = entry + 4 + MemoryLayout<attribute_set_t>.size
            func next<T>(_: T.Type) -> T { defer { p += MemoryLayout<T>.size }; return p.loadUnaligned(as: T.self) }
            let nameRef = p, ref = next(attrreference_t.self)
            let name = Array(UnsafeRawBufferPointer(start: nameRef + Int(ref.attr_dataoffset),
                                                    count: max(0, Int(ref.attr_length) - 1)))
            var fs = FileStat()
            fs.dev = u32(next(dev_t.self))
            let type = next(fsobj_type_t.self)
            fs.mtime = next(timespec.self)
            fs.ctime = next(timespec.self)
            fs.uid = next(uid_t.self)
            fs.gid = next(gid_t.self)
            let perms = next(UInt32.self) & 0o7777
            fs.ino = next(UInt64.self)
            fs.size = next(Int64.self)
            switch Int(type) {
            case Int(VREG.rawValue): fs.mode = UInt32(S_IFREG) | perms
            case Int(VLNK.rawValue): fs.mode = UInt32(S_IFLNK) | perms
            case Int(VDIR.rawValue): fs.mode = UInt32(S_IFDIR) | perms
            default: fs.mode = perms
            }
            out[name] = fs
            entry += Int(entry.loadUnaligned(as: UInt32.self))
        }
    }
    return out
}

func provenByIndex(_ e: IndexEntry, src: FileStat, dst: FileStat, _ claim: StatClaim?, indexMtime: Int) -> Bool {
    guard let c = claim, c.entry.oid == e.oid, c.entry.mode == e.mode, Int(c.mtime.sec) < indexMtime,
          c.ctime == (u32(src.ctime.tv_sec), u32(src.ctime.tv_nsec)),
          c.ino == u32(src.ino),
          c.mtime == (u32(src.mtime.tv_sec), u32(src.mtime.tv_nsec)),
          c.mtime == (u32(dst.mtime.tv_sec), u32(dst.mtime.tv_nsec)),
          c.size == u32(src.size), c.size == u32(dst.size),
          src.mode == dst.mode else { return false }
    switch e.mode {
    case 0o100644: return dst.type == S_IFREG && dst.mode & UInt32(S_IXUSR) == 0
    case 0o100755: return dst.type == S_IFREG && dst.mode & UInt32(S_IXUSR) != 0
    case 0o120000: return dst.type == S_IFLNK
    default: return false
    }
}

func readIndex(_ path: String, oidLen: Int) -> (entries: [IndexEntry], tree: [UInt8])? {
    guard let d = fm.contents(atPath: path).map({ [UInt8]($0) }), d.count >= 12 + oidLen,
          d[0..<4].elementsEqual("DIRC".utf8) else { return nil }
    func be<T: FixedWidthInteger>(_ o: Int, _: T.Type) -> T {
        d.withUnsafeBytes { T(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: T.self)) }
    }
    guard be(4, UInt32.self) == 2 else { return nil }
    let count = Int(be(8, UInt32.self))
    let end = d.count - oidLen
    var entries: [IndexEntry] = []
    entries.reserveCapacity(count)
    var o = 12
    for _ in 0..<count {
        let nameAt = o + 40 + oidLen + 2
        guard nameAt <= end else { return nil }
        let flags = be(o + 40 + oidLen, UInt16.self)
        // Extended flags are v3; a long name runs to its NUL.
        guard flags & 0x4000 == 0, flags & 0x3000 == 0 else { return nil }
        var len = Int(flags & 0xFFF)
        if len == 0xFFF {
            guard let nul = d[nameAt..<end].firstIndex(of: 0) else { return nil }
            len = nul - nameAt
        }
        guard nameAt + len < end else { return nil }
        entries.append(IndexEntry(mode: be(o + 24, UInt32.self), oid: Array(d[(o + 40)..<(o + 40 + oidLen)]),
                                  path: Array(d[nameAt..<(nameAt + len)])))
        o += (40 + oidLen + 2 + len + 8) & ~7
    }
    var tree: [UInt8] = []
    while o + 8 <= end {
        let extEnd = o + 8 + Int(be(o + 4, UInt32.self))
        guard extEnd <= end else { return nil }
        if d[o..<(o + 4)].elementsEqual("TREE".utf8) { tree = Array(d[o..<extEnd]) }
        o = extEnd
    }
    return (entries, tree)
}

func writeIndex(_ path: String, _ entries: [IndexEntry], oidLen: Int, tree: [UInt8],
                _ stats: UnsafeBufferPointer<FileStat?>) throws(Fail) {
    // NUL-terminated, padded to a multiple of 8 bytes.
    func entrySize(_ e: IndexEntry) -> Int { (40 + oidLen + 2 + e.path.count + 8) & ~7 }
    let size = 12 + entries.reduce(0) { $0 + entrySize($1) } + tree.count + oidLen
    var d = [UInt8](repeating: 0, count: size)
    d.withUnsafeMutableBytes { buf in
        var o = 0
        func be32<T: BinaryInteger>(_ v: T) { buf.storeBytes(of: u32(v).bigEndian, toByteOffset: o, as: UInt32.self); o += 4 }
        for c in "DIRC".utf8 { buf[o] = c; o += 1 }
        be32(2)
        be32(entries.count)
        for (k, e) in entries.enumerated() {
            let start = o
            if let s = stats[k] {
                be32(s.ctime.tv_sec); be32(s.ctime.tv_nsec)
                be32(s.mtime.tv_sec); be32(s.mtime.tv_nsec)
                be32(s.dev); be32(s.ino); be32(e.mode); be32(s.uid); be32(s.gid); be32(s.size)
            } else {
                o += 24
                be32(e.mode)
                o += 12
            }
            for c in e.oid { buf[o] = c; o += 1 }
            buf.storeBytes(of: UInt16(min(e.path.count, 0xFFF)).bigEndian, toByteOffset: o, as: UInt16.self)
            o += 2
            for c in e.path { buf[o] = c; o += 1 }
            o = start + entrySize(e)
        }
        for c in tree { buf[o] = c; o += 1 }
    }
    let body = d[..<(size - oidLen)]
    let sum = oidLen == 32 ? Array(SHA256.hash(data: body)) : Array(Insecure.SHA1.hash(data: body))
    d.replaceSubrange((size - oidLen)..., with: sum)
    let lock = path + ".lock"
    do { try Data(d).write(to: URL(fileURLWithPath: lock), options: .withoutOverwriting) } catch {
        throw die("cannot write \(lock): \(errText(error))")
    }
    if rename(lock, path) != 0 {
        let e = errno
        removeTree(lock)
        throw die("cannot write \(path): \(errText(e))")
    }
}

// MARK: - Clone plan

/// A directory of REF's tree.
struct TreeDir {
    let path: [UInt8]   // relative; empty for the root
    let name: [UInt8]
    var files: [Int] = []   // indices into the entries (files, symlinks, gitlinks)
    var dirs: [Int] = []    // indices into the TreeDirs
}

func treeDirs(_ entries: [IndexEntry]) -> [TreeDir] {
    var dirs = [TreeDir(path: [], name: [])]
    var byPath: [[UInt8]: Int] = [[]: 0]
    func dir(_ p: ArraySlice<UInt8>) -> Int {
        if let d = byPath[Array(p)] { return d }
        let slash = p.lastIndex(of: UInt8(ascii: "/"))
        let parent = slash.map { dir(p[..<$0]) } ?? 0
        let name = slash.map { Array(p[($0 + 1)...]) } ?? Array(p)
        dirs.append(TreeDir(path: Array(p), name: name))
        dirs[parent].dirs.append(dirs.count - 1)
        byPath[Array(p)] = dirs.count - 1
        return dirs.count - 1
    }
    var last: (path: ArraySlice<UInt8>, dir: Int) = ([], 0)
    for (k, e) in entries.enumerated() {
        let p = e.path.lastIndex(of: UInt8(ascii: "/")).map { e.path[..<$0] } ?? []
        if p != last.path { last = (p, dir(p)) }
        dirs[last.dir].files.append(k)
    }
    return dirs
}

func pureDirs(_ src: String, _ dirs: [TreeDir], _ entries: [IndexEntry],
              _ inSource: UnsafeMutableBufferPointer<Bool>) -> [Bool] {
    let local = UnsafeMutableBufferPointer<Bool>.allocate(capacity: dirs.count)
    defer { local.deallocate() }
    nonisolated(unsafe) let localOut = local, inSourceOut = inSource
    DispatchQueue.concurrentPerform(iterations: dirs.count) { di in
        let d = dirs[di]
        // name -> (entry index or -1 for a directory, wanted d_type)
        var want: [[UInt8]: (k: Int, type: Int32)] = [:]
        var pure = di != 0
        for k in d.files {
            let e = entries[k]
            let name = Array(e.path[((e.path.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1)...])
            switch e.mode {
            case 0o120000: want[name] = (k, DT_LNK)
            case gitlinkMode: pure = false
            default: want[name] = (k, DT_REG)
            }
            inSourceOut[k] = false
        }
        for s in d.dirs { want[dirs[s].name] = (-1, DT_DIR) }
        var seen = 0
        let path = src + (d.path.isEmpty ? "" : "/" + String(decoding: d.path, as: UTF8.self))
        if let dp = opendir(path) {
            while let ent = readdir(dp) {
                let name = withUnsafeBytes(of: &ent.pointee.d_name) { Array($0.prefix(Int(ent.pointee.d_namlen))) }
                if name == [UInt8(ascii: ".")] || name == [UInt8(ascii: "."), UInt8(ascii: ".")] { continue }
                var type = Int32(ent.pointee.d_type)
                if type == DT_UNKNOWN {
                    var st = stat()
                    lstat(path + "/" + String(decoding: name, as: UTF8.self), &st)
                    type = st.st_mode & S_IFMT == S_IFDIR ? DT_DIR : st.st_mode & S_IFMT == S_IFLNK ? DT_LNK : DT_REG
                }
                guard let w = want[name], (w.type == type || (w.k >= 0 && type != DT_DIR)) else { pure = false; continue }
                if w.type != type { pure = false }
                if w.k >= 0 { inSourceOut[w.k] = true }
                seen += 1
            }
            closedir(dp)
        } else {
            pure = false
        }
        localOut[di] = pure && seen == want.count
    }
    // Subdirectories come after their parent.
    var pure = Array(local)
    for di in pure.indices.reversed() where pure[di] {
        pure[di] = dirs[di].dirs.allSatisfy { pure[$0] }
    }
    return pure
}

func gitPath(_ worktree: String, _ name: String) throws(Fail) -> String {
    let r = try check(run(["git", "-C", worktree, "rev-parse", "--git-path", name], stdout: .capture))
    let p = lines(r.out).first ?? ""
    return p.hasPrefix("/") ? p : worktree + "/" + p
}

// MARK: - Arguments

struct Options {
    var dest = ""
    var ref = ""
    var newBranch = ""
    var source = ""
    var copies: [String] = []
    var timings = false
}

func parseArgs(_ argv: [String]) throws(Fail) -> Options {
    var o = Options()
    var i = 0
    func value(_ msg: String) throws(Fail) -> String {
        if i + 1 >= argv.count { throw die(msg) }
        i += 1
        return argv[i]
    }
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "-h", "--help":
            writeFD(.standardOutput, usage)
            throw Fail(code: 0)
        case "-b": o.newBranch = try value("-b needs a branch name")
        case "--source": o.source = try value("--source needs a directory")
        case "--copy":
            let rel = stripOneSlash(try value("--copy needs a path"))
            let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
            if rel.hasPrefix("/") || parts.contains(where: { ["", ".", ".."].contains($0) }) || parts[0] == ".git" {
                throw die("--copy needs a path inside the repo, relative to its root: \(rel)")
            }
            if !o.copies.contains(rel) { o.copies.append(rel) }
        case "--timings": o.timings = true
        default:
            if a.hasPrefix("-") { throw die("unknown option: \(a) (see --help)") }
            if o.dest.isEmpty { o.dest = a }
            else if o.ref.isEmpty { o.ref = a }
            else { throw die("unexpected argument: \(a)") }
        }
        i += 1
    }
    if o.dest.isEmpty || o.ref.isEmpty {
        writeFD(.standardError, usage)
        throw Fail(code: 2)
    }
    return o
}

// MARK: - Main flow

final class RunState {
    var src = ""
    var dest = ""
    var newBranch = ""
    var createdWorktree = false
    var createdBranch = false
    var complete = false

    func cleanup(_ rc: Int32) {
        if rc != 0 && createdWorktree && !complete {
            sayErr("we failed (exit \(rc)). removing worktree @ \(dest)")
            let r = try? run(["git", "-C", src, "worktree", "remove", "--force", dest],
                             stdout: .null, stderr: .null)
            if r?.status != 0 {
                sayErr("manual cleanup needed!! please run: git worktree remove --force '\(dest)'")
            }
            if createdBranch {
                _ = try? run(["git", "-C", src, "branch", "-D", newBranch], stdout: .null, stderr: .null)
            }
        }
    }
}

func gitWtAdd(_ o: Options, _ st: RunState, _ t: Timings) throws(Fail) {
    if which("git") == nil { throw die("git not found") }

    var source = o.source
    if source.isEmpty {
        let r = try run(["git", "worktree", "list", "--porcelain"], stdout: .capture)
        if r.status != 0 { throw die("you're not inside a git repository (use --source DIR)") }
        source = lines(r.out).first { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) } ?? ""
    }
    guard isDir(source) else { throw die("--source is not a git worktree: \(source)") }
    let top = try run(["git", "-C", source, "rev-parse", "--show-toplevel", "--show-object-format"], stdout: .capture)
    guard top.status == 0, let topDir = lines(top.out).first, let SRC = realPath(topDir) else {
        throw die("--source is not a git worktree: \(source)")
    }
    let oidLen = lines(top.out).dropFirst().first == "sha256" ? 32 : 20

    var destRaw = o.dest.hasPrefix("/") ? o.dest : currentDir() + "/" + o.dest
    destRaw = stripOneSlash(destRaw)
    let parent = dirname(destRaw)
    guard isDir(parent) else { throw die("parent directory does not exist: \(parent)") }
    let lexical = URL(fileURLWithPath: parent).standardized.path
    guard let parentReal = realPath(lexical) ?? realPath(parent) else {
        throw die("parent directory does not exist: \(parent)")
    }
    let DEST = (parentReal == "/" ? "" : parentReal) + "/" + basename(destRaw)
    st.src = SRC
    st.dest = DEST
    st.newBranch = o.newBranch

    if existsOrLink(DEST) { throw die("PATH already exists: \(DEST)") }
    if DEST == SRC { throw die("PATH is the source worktree") }

    if !o.newBranch.isEmpty {
        let r = try run(["git", "-C", SRC, "show-ref", "--verify", "--quiet", "refs/heads/\(o.newBranch)"])
        if r.status == 0 { throw die("branch already exists: \(o.newBranch)") }
    }

    let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeNameKey, .volumeSupportsFileCloningKey]
    let sv = try? URL(fileURLWithPath: SRC).resourceValues(forKeys: keys)
    let dv = try? URL(fileURLWithPath: parent).resourceValues(forKeys: keys)
    if sv?.volumeIdentifier as? NSObject != dv?.volumeIdentifier as? NSObject {
        sayErr("WARNING! source (\(SRC)) and destination (\(parent)) are on different volumes (\(sv?.volumeName ?? "?") vs \(dv?.volumeName ?? "?")). This will use a slow copy, rather than copy on write. You may want to abort if you have a checkout on target volume you can use.")
    } else if dv?.volumeSupportsFileCloning != true {
        sayErr("WARNING! \(parent) is on a volume without clones (not APFS?). We will perform a slow copy instead.")
    }

    // A cloned worktree's .git file would still point at that worktree's admin dir.
    let wl = try check(run(["git", "-C", SRC, "worktree", "list", "--porcelain"], stdout: .capture))
    let nested = lines(wl.out).filter { $0.hasPrefix("worktree \(SRC)/") }.map { String($0.dropFirst(10 + SRC.count)) }
    var copies: [String] = []
    for rel in o.copies {
        if let w = nested.first(where: { $0 == rel || $0.hasPrefix(rel + "/") }) {
            throw die("--copy \(rel) contains the worktree \(w)")
        }
        if rel != venvDir && !existsOrLink(SRC + "/" + rel) {
            sayErr("WARNING --copy \(rel): not in the source, skipped")
            continue
        }
        copies.append(rel)
    }
    t.mark("setup")

    let start = nowNs()

    var add = ["git", "-C", SRC, "worktree", "add", "--no-checkout"]
    if !o.newBranch.isEmpty { add += ["-b", o.newBranch] }
    try check(run(add + [DEST, o.ref]))
    st.createdBranch = !o.newBranch.isEmpty
    st.createdWorktree = true
    say("worktree created at \(DEST)")
    t.mark("worktree-add")
    try checkInterrupted()

    // git reset --hard rewrites every file... which for copy-on-write will break our entire approach
    // as such do this stuff instead
    try check(run(["git", "-c", "core.splitIndex=false", "-c", "index.skipHash=false", "-C", DEST, "read-tree", "HEAD"],
                  env: ["GIT_INDEX_VERSION": "2"]))
    t.mark("read-tree")
    let destIndex = try gitPath(DEST, "index")
    let entries: [IndexEntry], tree: [UInt8]
    if let r = readIndex(destIndex, oidLen: oidLen) {
        (entries, tree) = (r.entries, r.tree)
    } else {
        let index = try check(run(["git", "-C", DEST, "ls-files", "-s", "-z"], stdout: .capture))
        guard let e = parseEntries(index.out) else { throw die("unexpected git ls-files output") }
        (entries, tree) = (e, [])
    }
    var madeDirs: Set<String> = []
    func mkdirs(_ d: String) throws(Fail) {
        if madeDirs.contains(d) { return }
        do { try fm.createDirectory(atPath: d, withIntermediateDirectories: true) } catch {
            throw die("mkdir \(d): \(errText(error))")
        }
        madeDirs.insert(d)
    }
    t.mark("entries")

    // git would hash every clone before trusting it which is Slow :(
    var ist = stat()
    var claims: [StatClaim] = []
    if lstat(try gitPath(SRC, "index"), &ist) == 0 {
        let r = try run(["git", "-C", SRC, "ls-files", "-s", "--debug", "-z"], stdout: .capture)
        if r.status == 0 { claims = parseStatClaims(r.out) ?? [] }
    }
    let claimOf = matchClaims(entries, claims)
    let srcClaims = claims
    t.mark("claims")

    // build data for our threads to operate upon. we prefer directories where we can get away with it
    let n = entries.count
    let inSource = UnsafeMutableBufferPointer<Bool>.allocate(capacity: n)
    defer { inSource.deallocate() }
    let dirs = treeDirs(entries)
    let pure = pureDirs(SRC, dirs, entries, inSource)
    var dirJobs: [CloneJob] = [], fileJobs: [CloneJob] = []
    @Sendable func rel(_ p: [UInt8]) -> String { "/" + String(decoding: p, as: UTF8.self) }
    func plan(_ di: Int) throws(Fail) {
        for sd in dirs[di].dirs {
            let r = rel(dirs[sd].path)
            if pure[sd] {
                dirJobs.append(CloneJob(src: SRC + r, dst: DEST + r))
            } else {
                if mkdir(DEST + r, 0o777) != 0 { throw die("mkdir \(DEST + r): \(errText(errno))") }
                try plan(sd)
            }
        }
        for k in dirs[di].files {
            let r = rel(entries[k].path)
            if entries[k].mode == gitlinkMode {
                // A submodule is an empty dir, as git worktree add leaves it.
                if mkdir(DEST + r, 0o777) != 0 { throw die("mkdir \(DEST + r): \(errText(errno))") }
            } else if inSource[k] {
                fileJobs.append(CloneJob(src: SRC + r, dst: DEST + r))
            }
        }
    }
    try plan(0)
    t.mark("plan")

    // run dirs first, they take the longest
    if let (job, e) = runCloneJobs(dirJobs + fileJobs) {
        throw die("clone failed: \(relPath(job.src, under: SRC)): \(errText(e))")
    }
    try checkInterrupted()
    t.mark("clone")

    let stats = UnsafeMutableBufferPointer<FileStat?>.allocate(capacity: n)
    defer { stats.deallocate() }
    nonisolated(unsafe) let statsOut = stats
    let indexMtime = Int(ist.st_mtimespec.tv_sec)
    @Sendable func lstatAt(_ p: String) -> FileStat? {
        var st = stat()
        return lstat(p, &st) == 0 ? FileStat(st) : nil
    }
    // names in DEST that REF doesn't have
    // e.g. something appeared in the source between planning and cloning
    let strays = Mutex<[String]>([])
    let unlisted = Atomic<Bool>(false)
    DispatchQueue.concurrentPerform(iterations: dirs.count) { di in
        let d = dirs[di], r = d.path.isEmpty ? "" : rel(d.path)
        let srcStats = dirStats(SRC + r), dstStats = dirStats(DEST + r)
        if let dstStats {
            var known = Set(d.dirs.map { dirs[$0].name })
            if di == 0 { known.insert(Array(".git".utf8)) }
            for k in d.files { known.insert(Array(entries[k].path.split(separator: UInt8(ascii: "/")).last ?? [])) }
            let extra = dstStats.keys.filter { !known.contains($0) }
            if !extra.isEmpty { strays.withLock { $0 += extra.map { r + "/" + String(decoding: $0, as: UTF8.self) } } }
        } else {
            unlisted.store(true, ordering: .relaxed)
        }
        for k in d.files {
            let e = entries[k]
            let name = Array(e.path[((e.path.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1)...])
            guard let dst = dstStats.map({ $0[name] }) ?? lstatAt(DEST + rel(e.path)),
                  let src = srcStats.map({ $0[name] }) ?? lstatAt(SRC + rel(e.path)),
                  provenByIndex(e, src: src, dst: dst, claimOf[k] < 0 ? nil : srcClaims[claimOf[k]],
                                indexMtime: indexMtime) else { statsOut[k] = nil; continue }
            statsOut[k] = dst
        }
    }
    let unproven = stats.count { $0 == nil }
    let removed = strays.withLock { $0 }.sorted()
    for p in removed { removeTree(DEST + p) }
    if !removed.isEmpty {
        sayErr("WARNING removed \(removed.count) paths that appeared in the source while cloning: "
               + removed.prefix(5).map { String($0.dropFirst()) }.joined(separator: ", "))
    }
    t.mark("prove")
    try writeIndex(destIndex, entries, oidLen: oidLen, tree: tree, UnsafeBufferPointer(stats))
    say("cloned \(n) tracked files (\(dirJobs.count) whole directories; \(unproven) left for git to verify)")
    t.mark("index")

    if unproven > 0 {
        let diff = try check(run(["git", "-C", DEST, "diff", "--name-only", "-z"], stdout: .capture))
        if !diff.out.isEmpty {
            try check(run(["git", "-C", DEST, "checkout-index", "-f", "-z", "--stdin"], input: diff.out))
        }
    }
    t.mark("checkout")
    try checkInterrupted()

    if unproven > 0 || unlisted.load(ordering: .relaxed) {
        let status = try check(run(["git", "-C", DEST, "status", "--porcelain"], stdout: .capture))
        let dirty = lines(status.out)
        if !dirty.isEmpty {
            writeFD(.standardError, dirty.joined(separator: "\n") + "\n")
            throw die("worktree not clean after checkout!!!")
        }
        say("git status clean")
    }
    t.mark("status")

    let uvVenv = copies.contains(venvDir) && which("uv") != nil && isRegularFile(DEST + "/pyproject.toml")
    var copyJobs: [CloneJob] = []
    for rel in copies where !(rel == venvDir && uvVenv) {
        if !existsOrLink(SRC + "/" + rel) {
            sayErr("WARNING --copy \(rel): not in the source and uv or pyproject.toml missing, skipped")
            continue
        }
        let d = DEST + "/" + rel
        if existsOrLink(d) { throw die("--copy \(rel): already in the worktree (tracked files are always cloned)") }
        try mkdirs(dirname(d))
        copyJobs.append(CloneJob(src: SRC + "/" + rel, dst: d))
    }
    if let (job, e) = runCloneJobs(copyJobs) {
        throw die("clone failed: \(relPath(job.src, under: SRC)): \(errText(e))")
    }
    try checkInterrupted()
    for j in copyJobs { say("copied \(relPath(j.src, under: SRC))") }
    t.mark("copy")

    // a cloned .venv has the source's paths baked into its scripts
    // uv does copy on write from it's cache anyway, so this is kind of a moot point
    if uvVenv {
        say("building .venv with uv sync --frozen (link-mode clone)")
        let r = try run(["uv", "sync", "--frozen", "--directory", DEST],
                        env: ["UV_PROJECT_ENVIRONMENT": nil, "UV_LINK_MODE": "clone"])
        if r.status != 0 { throw die("uv sync failed in \(DEST)") }
    } else if copyJobs.contains(where: { $0.dst == DEST + "/" + venvDir }) {
        sayErr("WARNING copied .venv still points at the source (uv or pyproject.toml missing)")
    }
    t.mark("venv")

    st.complete = true
    say("done in \((nowNs() - start) / 1_000_000_000)s: \(DEST)")
    if o.timings { sayErr("timings: \(t.line)") }
}

func main() -> Int32 {
    installSignalHandlers()
    let timings = Timings()
    let state = RunState()
    var rc: Int32 = 0
    do {
        let opts = try parseArgs(Array(CommandLine.arguments.dropFirst()))
        try gitWtAdd(opts, state, timings)
    } catch {
        rc = error.code
    }
    let sig = interruptedBy.load(ordering: .relaxed)
    if rc == 0 && sig != 0 { rc = 128 + sig }
    state.cleanup(rc)
    return rc
}

exit(main())
