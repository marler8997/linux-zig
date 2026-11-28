/// The caller broke a documented contract. Panics in safe builds and is
/// unreachable in release builds, so only call it for an errno or state that
/// correct use can never produce.
pub fn apiMisuse(comptime msg: []const u8, args: anytype) noreturn {
    if (std.debug.runtime_safety) std.debug.panic(msg, args);
    unreachable;
}

/// For wrappers that don't return an errno, because correct use can't make
/// their syscall fail. If it fails anyway, either the caller misused it in a
/// way linux-zig didn't anticipate, or linux-zig is wrong and correct use can
/// make it fail. The second can happen in a correct program, so unlike
/// apiMisuse this panics in release builds too.
fn panicUnexpectedErrno(comptime syscall: []const u8, errno: std.os.linux.E) noreturn {
    std.debug.panic("{s} returned unexpected errno {d}", .{ syscall, errno });
}

pub const FdKind = enum {
    any,
    pipe,
    socket,
    tty,
    epoll,
    eventfd,
    memfd,
    dev_null,
    /// Opened with O_PATH, whatever the file is.
    o_path,
};
pub const CloseKind = struct {
    flush: enum { possible, impossible, ignored } = .possible,

    /// The fd's file has no flush operation, so close can't fail.
    pub const flush_unreachable: CloseKind = .{ .flush = .impossible };
    /// Use it when a flush error doesn't matter: a file opened only for
    /// reading, a lock file, a directory, or an fd of unknown kind, such as one
    /// inherited from another process. For a written file whose contents must
    /// reach storage, use FileSync.
    pub const ignore_flush_error: CloseKind = .{ .flush = .ignored };

    // one per FdKind, so a caller can write close(.pipe, fd)
    pub const any: CloseKind = .fromFdKind(.any);
    pub const pipe: CloseKind = .fromFdKind(.pipe);
    pub const socket: CloseKind = .fromFdKind(.socket);
    pub const tty: CloseKind = .fromFdKind(.tty);
    pub const epoll: CloseKind = .fromFdKind(.epoll);
    pub const eventfd: CloseKind = .fromFdKind(.eventfd);
    pub const memfd: CloseKind = .fromFdKind(.memfd);
    pub const dev_null: CloseKind = .fromFdKind(.dev_null);
    pub const o_path: CloseKind = .fromFdKind(.o_path);

    pub fn fromFdKind(comptime kind: FdKind) CloseKind {
        return switch (kind) {
            .any => .{},
            .pipe,
            .socket,
            .tty,
            .epoll,
            .eventfd,
            .memfd,
            .dev_null,
            .o_path,
            => .flush_unreachable,
        };
    }
};
/// The close syscall always releases the given fd. A non-zero errno indicates
/// an error occurred during flush (fs/open.c): NFS sends cached writes to the
/// server on close and returns their error, and a FUSE server can reply with
/// any errno up to 511, even for a file opened only for reading. EBADF can also
/// mean fd wasn't open. Use .ignore_flush_error to ignore the errno.
pub fn close(comptime kind: CloseKind, fd: std.os.linux.fd_t) switch (kind.flush) {
    .possible => std.os.linux.E,
    .impossible, .ignored => void,
} {
    const errno = std.os.linux.errno(std.os.linux.close(fd));
    switch (kind.flush) {
        .possible => return errno,
        .impossible => if (errno != .SUCCESS) {
            apiMisuse("close fd {} returned errno {d}", .{ fd, errno });
        },
        .ignored => {},
    }
}

/// Writes fd's file back to storage. A non-zero errno means its contents may
/// not have reached storage. fd must not be opened with O_PATH.
pub fn fsync(fd: std.os.linux.fd_t) std.os.linux.E {
    while (true) switch (std.os.linux.errno(std.os.linux.fsync(fd))) {
        .INTR => continue,
        else => |e| return e,
    };
}

/// Syncs a written file to storage and closes it, reporting whether its
/// contents reached storage. A newly created file's name also needs its
/// directory synced to survive a crash. Pair syncClose with a deferred cancel
/// so the fd is closed exactly once on every path:
///
///     const fd = switch (linux.open(...)) { .fd => |fd| fd, .errno => ... };
///     var file_sync: linux.FileSync = .{};
///     defer file_sync.cancel(fd);
///     // write
///     if (file_sync.syncClose(fd)) |failure| // the file wasn't saved
pub const FileSync = struct {
    closed: bool = false,

    /// Closes fd unless syncClose already did. Ignores a flush error: the save
    /// has already failed or been abandoned.
    pub fn cancel(file_sync: *FileSync, fd: std.os.linux.fd_t) void {
        if (!file_sync.closed) {
            file_sync.closed = true;
            close(.ignore_flush_error, fd);
        }
    }

    /// The step that failed and its errno.
    pub const SyncCloseFailure = struct {
        op: enum { fsync, close },
        errno: std.os.linux.E,

        pub fn format(failure: SyncCloseFailure, writer: *std.Io.Writer) error{WriteFailed}!void {
            try writer.print("{t} failed, errno {d}", .{ failure.op, failure.errno });
        }
    };
    /// Syncs fd to storage and closes it. Returns the failure if the contents
    /// may not have reached storage. fd is closed either way.
    pub fn syncClose(file_sync: *FileSync, fd: std.os.linux.fd_t) ?SyncCloseFailure {
        if (file_sync.closed) apiMisuse("FileSync.syncClose fd {} already closed", .{fd});
        file_sync.closed = true;
        switch (fsync(fd)) {
            .SUCCESS => {},
            else => |errno| {
                close(.ignore_flush_error, fd);
                return .{ .op = .fsync, .errno = errno };
            },
        }
        // FUSE sends close's flush to its server, which can fail it even after
        // a successful fsync.
        return switch (close(.any, fd)) {
            .SUCCESS => null,
            else => |errno| .{ .op = .close, .errno = errno },
        };
    }
};

/// Closes every open fd from first to last inclusive; first must not be greater
/// than last. close_range doesn't report flush errors. ENOSYS means Linux
/// before 5.9; a seccomp filter older than the syscall, such as Docker's
/// before 20.10, returns EPERM instead.
pub fn closeRange(first: std.os.linux.fd_t, last: std.os.linux.fd_t) std.os.linux.E {
    const rc = std.os.linux.syscall3(
        .close_range,
        @as(u32, @intCast(first)),
        @as(u32, @intCast(last)),
        0,
    );
    return switch (std.os.linux.errno(rc)) {
        .INVAL => apiMisuse("close_range first {} last {} returned EINVAL", .{ first, last }),
        else => |e| e,
    };
}

pub const FdResult = union(enum) { fd: std.os.linux.fd_t, errno: std.os.linux.E };
pub const FdPairResult = union(enum) { fds: [2]std.os.linux.fd_t, errno: std.os.linux.E };

pub const DirFd = enum(std.os.linux.fd_t) {
    cwd = std.os.linux.AT.FDCWD,
    _,

    pub fn fromFd(fd: std.os.linux.fd_t) DirFd {
        return @fromBackingInt(@intCast(fd));
    }
};

/// Whether a new fd is non-blocking and close-on-exec. Every call that creates
/// an fd takes these. cloexec defaults to true, since an fd a child should
/// inherit is the exception.
pub const FdFlags = struct {
    nonblock: bool = false,
    cloexec: bool = true,

    pub const nonblocking: FdFlags = .{ .nonblock = true };
};

/// std.os.linux.O with CLOEXEC defaulting to true, like FdFlags, and LARGEFILE
/// defaulting to true, without which a 32-bit process can't open a file of
/// 2 GiB or more, or write past 2 GiB.
pub const OpenFlags = blk: {
    const info = @typeInfo(std.os.linux.O).@"struct";
    var attrs = info.field_attrs[0..info.field_attrs.len].*;
    for (info.field_names, &attrs) |name, *attr| {
        if (std.mem.eql(u8, name, "CLOEXEC")) attr.default_value_ptr = &true;
        if (std.mem.eql(u8, name, "LARGEFILE")) attr.default_value_ptr = &true;
    }
    break :blk @Struct(
        .@"packed",
        info.backing_integer,
        info.field_names,
        info.field_types,
        &attrs,
    );
};

/// ENOENT means path doesn't exist, and EEXIST that it does with EXCL. Opening
/// a FIFO waits for the other end, so a signal can interrupt it with EINTR.
pub fn open(
    dir_fd: DirFd,
    path: [*:0]const u8,
    flags: OpenFlags,
    mode: std.os.linux.mode_t,
) FdResult {
    const rc = std.os.linux.openat(@backingInt(dir_fd), path, @bitCast(flags), mode);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .fd = @intCast(rc) },
        else => |e| .{ .errno = e },
    };
}

/// Opens /dev/null on whichever of fds 0, 1 and 2 are closed. Call it at
/// startup, before other threads exist, in a daemon, a setuid program, or
/// anything started by a parent you don't control. Otherwise a later open can
/// return a std fd, so writes meant for stdout or stderr go into that file, and
/// a dup2 onto the std fd closes it.
pub fn openStdFds() std.os.linux.E {
    for (0..3) |fd| switch (std.os.linux.errno(std.os.linux.fcntl(
        @intCast(fd),
        std.os.linux.F.GETFD,
        0,
    ))) {
        .SUCCESS => {},
        // the fds below this one are open, so open returns this one
        // the std fds have to survive exec
        .BADF => switch (open(
            undefined,
            "/dev/null",
            .{ .ACCMODE = .RDWR, .CLOEXEC = false },
            0,
        )) {
            .fd => |new_fd| if (new_fd != fd) apiMisuse(
                "openStdFds opened fd {} instead of {}",
                .{ new_fd, fd },
            ),
            .errno => |e| return e,
        },
        else => |e| return e,
    };
    return .SUCCESS;
}

pub const ReadlinkResult = union(enum) { target: []u8, errno: std.os.linux.E };
/// buf must not be empty. A target that fills buf may have been truncated; like
/// the syscall, this doesn't report it. EINVAL means path isn't a symlink.
pub fn readlink(dir_fd: DirFd, path: [*:0]const u8, buf: []u8) ReadlinkResult {
    if (buf.len == 0) apiMisuse("readlink with an empty buf", .{});
    while (true) {
        const rc = std.os.linux.readlinkat(@backingInt(dir_fd), path, buf.ptr, buf.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return .{ .target = buf[0..rc] },
            .INTR => continue,
            else => |e| return .{ .errno = e },
        }
    }
}

pub fn chdir(path: [*:0]const u8) std.os.linux.E {
    while (true) switch (std.os.linux.errno(std.os.linux.chdir(path))) {
        .INTR => continue,
        else => |e| return e,
    };
}

/// With cloexec, an RLIMIT_NOFILE of 0 returns EINVAL instead of EMFILE.
pub fn dup(fd: std.os.linux.fd_t, opt: struct { cloexec: bool = true }) FdResult {
    const rc = if (opt.cloexec) std.os.linux.fcntl(
        fd,
        std.os.linux.F.DUPFD_CLOEXEC,
        0,
    ) else std.os.linux.dup(fd);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .fd = @intCast(rc) },
        .BADF => apiMisuse("dup fd {} returned EBADF", .{fd}),
        else => |e| .{ .errno = e },
    };
}

/// Makes new_fd refer to old_fd's file, without close-on-exec, so a child
/// inherits it across exec. Unlike the syscall, this also holds when old_fd
/// and new_fd are equal: it clears close-on-exec instead of leaving it set.
/// old_fd must be open. EBADF means new_fd is at or above RLIMIT_NOFILE, which
/// can be lowered below fds a process already has open.
pub fn dup2(old_fd: std.os.linux.fd_t, new_fd: std.os.linux.fd_t) std.os.linux.E {
    if (old_fd == new_fd) return switch (std.os.linux.errno(std.os.linux.fcntl(
        old_fd,
        std.os.linux.F.SETFD,
        0,
    ))) {
        .BADF => apiMisuse("dup2 fd {} returned EBADF", .{old_fd}),
        else => |e| e,
    };
    while (true) switch (std.os.linux.errno(std.os.linux.dup2(old_fd, new_fd))) {
        // EBUSY is a race with another thread's open of new_fd
        .BUSY => continue,
        else => |e| return e,
    };
}

/// EPERM means the caller is a process group leader. A forked child isn't one
/// unless it or its parent calls setpgid, as a job-control shell does.
pub fn setsid() std.os.linux.E {
    return std.os.linux.errno(std.os.linux.syscall0(.setsid));
}

/// sig must be a valid signal. ESRCH means the process doesn't exist.
pub fn kill(pid: std.os.linux.pid_t, sig: std.os.linux.SIG) std.os.linux.E {
    return switch (std.os.linux.errno(std.os.linux.kill(pid, sig))) {
        .INVAL => apiMisuse("kill sig {} returned EINVAL", .{@backingInt(sig)}),
        else => |e| e,
    };
}

pub fn pipe2(fd_flags: FdFlags) FdPairResult {
    var fds: [2]std.os.linux.fd_t = undefined;
    const flags: std.os.linux.O = .{ .CLOEXEC = fd_flags.cloexec, .NONBLOCK = fd_flags.nonblock };
    return switch (std.os.linux.errno(std.os.linux.pipe2(&fds, flags))) {
        .SUCCESS => .{ .fds = fds },
        else => |e| .{ .errno = e },
    };
}

pub const ForkResult = union(enum) { child, parent: std.os.linux.pid_t, errno: std.os.linux.E };
/// Makes the raw syscall, so libc's fork handlers don't run; a program linked
/// with libc should call libc's fork. EAGAIN means RLIMIT_NPROC or the pid
/// limit was reached.
pub fn fork() ForkResult {
    const rc = std.os.linux.fork();
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => if (rc == 0) .child else .{ .parent = @intCast(rc) },
        else => |e| .{ .errno = e },
    };
}

pub const WaitpidMode = enum {
    /// Wait for the child to exit.
    block,
    /// Return at once, with running if the child hasn't exited.
    nohang,
};
pub const WaitpidResult = union(enum) { status: u32, errno: std.os.linux.E };
pub const WaitpidNohangResult = union(enum) {
    status: u32,
    /// The child hasn't exited yet.
    running,
    errno: std.os.linux.E,
};
/// pid must be a child of this process that nothing else waits for. ECHILD
/// means the kernel already reaped it because SIGCHLD is ignored, a
/// disposition a process inherits across exec.
pub fn waitpid(comptime mode: WaitpidMode, pid: std.os.linux.pid_t) switch (mode) {
    .block => WaitpidResult,
    .nohang => WaitpidNohangResult,
} {
    var status: i32 = undefined;
    const flags: u32 = switch (mode) {
        .block => 0,
        .nohang => std.os.linux.W.NOHANG,
    };
    const rc = std.os.linux.waitpid(pid, &status, flags);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => switch (mode) {
            .block => .{ .status = @bitCast(status) },
            .nohang => if (rc == 0) .running else .{ .status = @bitCast(status) },
        },
        else => |e| .{ .errno = e },
    };
}

pub const ExecveKind = enum {
    /// A path, relative to dir_fd. A script run through a dir_fd with
    /// close-on-exec returns ENOENT, since its interpreter couldn't open it.
    path,
    /// The file fd refers to, such as a memfd. A script needs fd without
    /// close-on-exec, or the interpreter can't open it and the exec returns
    /// ENOENT.
    fd,
    /// Like execvp: a file without a '/' is tried in each directory of
    /// path_list (a PATH value), skipping empty entries and directories too
    /// long for PATH_MAX. Makes only syscalls, so a forked child can use it.
    /// If every exec fails, returns at once on an errno other than ENOENT,
    /// ENOTDIR or EACCES; otherwise EACCES if any directory returned it, else
    /// the last ENOENT or ENOTDIR. Unlike execvp, ENOEXEC is returned rather
    /// than retried with /bin/sh.
    search,
};
fn ExecveTarget(comptime kind: ExecveKind) type {
    return switch (kind) {
        .path => struct { dir_fd: DirFd, path: [*:0]const u8 },
        .fd => std.os.linux.fd_t,
        .search => struct { file: [*:0]const u8, path_list: []const u8 },
    };
}
/// Returns only if the exec failed.
pub fn execve(
    comptime kind: ExecveKind,
    target: ExecveTarget(kind),
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) std.os.linux.E {
    return switch (kind) {
        .path => std.os.linux.errno(std.os.linux.execveat(
            @backingInt(target.dir_fd),
            target.path,
            argv,
            envp,
            .{ .EMPTY_PATH = false, .SYMLINK_NOFOLLOW = false },
        )),
        .fd => std.os.linux.errno(std.os.linux.execveat(
            target,
            "",
            argv,
            envp,
            .{ .EMPTY_PATH = true, .SYMLINK_NOFOLLOW = false },
        )),
        .search => execveSearch(target.file, target.path_list, argv, envp),
    };
}
fn execveSearch(
    file: [*:0]const u8,
    path_list: []const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) std.os.linux.E {
    const name = std.mem.span(file);
    if (name.len == 0) return .NOENT;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return execve(.path, .{ .dir_fd = .cwd, .path = file }, argv, envp);
    }
    var path_buf: [std.os.linux.PATH_MAX]u8 = undefined;
    var result: std.os.linux.E = .NOENT;
    var it = std.mem.tokenizeScalar(u8, path_list, ':');
    while (it.next()) |dir| {
        const path_len = dir.len + 1 + name.len;
        if (path_len >= path_buf.len) continue;
        @memcpy(path_buf[0..dir.len], dir);
        path_buf[dir.len] = '/';
        @memcpy(path_buf[dir.len + 1 ..][0..name.len], name);
        path_buf[path_len] = 0;
        switch (execve(.path, .{ .dir_fd = .cwd, .path = path_buf[0..path_len :0] }, argv, envp)) {
            .ACCES => result = .ACCES,
            .NOENT, .NOTDIR => |e| if (result != .ACCES) {
                result = e;
            },
            else => |e| return e,
        }
    }
    return result;
}

pub const epoll = struct {
    pub fn create(opt: struct { cloexec: bool = true }) FdResult {
        const rc = std.os.linux.epoll_create1(if (opt.cloexec) std.os.linux.EPOLL.CLOEXEC else 0);
        return switch (std.os.linux.errno(rc)) {
            .SUCCESS => .{ .fd = @intCast(rc) },
            else => |e| .{ .errno = e },
        };
    }

    /// EPERM means fd doesn't support epoll, such as a regular file or a
    /// directory. ENOSPC means fs.epoll.max_user_watches was reached. EEXIST
    /// means fd's file is already in the set, which outlives closing fd while a
    /// dup of it stays open. ELOOP means fd is an epoll fd and adding it would
    /// create a loop or nest epoll fds more than 4 deep. EINVAL can mean the
    /// file is in too many nested epoll sets (reverse_path_check).
    pub fn add(
        epoll_fd: std.os.linux.fd_t,
        fd: std.os.linux.fd_t,
        events: u32,
        data: std.os.linux.epoll_data,
    ) std.os.linux.E {
        var event: std.os.linux.epoll_event = .{ .events = events, .data = data };
        return std.os.linux.errno(std.os.linux.epoll_ctl(
            epoll_fd,
            std.os.linux.EPOLL.CTL_ADD,
            fd,
            &event,
        ));
    }

    /// fd must be in the set.
    pub fn del(epoll_fd: std.os.linux.fd_t, fd: std.os.linux.fd_t) void {
        switch (std.os.linux.errno(std.os.linux.epoll_ctl(
            epoll_fd,
            std.os.linux.EPOLL.CTL_DEL,
            fd,
            null,
        ))) {
            .SUCCESS => {},
            .BADF, .INVAL, .PERM, .NOENT => |e| apiMisuse(
                "epoll_ctl DEL epoll fd {} fd {} returned errno {d}",
                .{ epoll_fd, fd, e },
            ),
            else => |e| panicUnexpectedErrno("epoll_ctl DEL", e),
        }
    }

    /// events must not be empty. Returns 0 ready on timeout. EINTR means a
    /// signal handler ran, or the process was stopped and continued, before
    /// the timeout.
    pub fn wait(
        epoll_fd: std.os.linux.fd_t,
        events: []std.os.linux.epoll_event,
        timeout_ms: i32,
    ) PollResult {
        if (events.len == 0) apiMisuse("epoll_wait with no events", .{});
        const max_events = std.math.maxInt(i32) / @sizeOf(std.os.linux.epoll_event);
        const rc = std.os.linux.epoll_wait(
            epoll_fd,
            events.ptr,
            @intCast(@min(events.len, max_events)),
            timeout_ms,
        );
        return switch (std.os.linux.errno(rc)) {
            .SUCCESS => .{ .ready = rc },
            else => |e| .{ .errno = e },
        };
    }
};

pub const eventfd = struct {
    pub fn create(
        initval: u32,
        fd_flags: FdFlags,
        opt: struct { semaphore: bool = false },
    ) FdResult {
        var flags: u32 = 0;
        if (fd_flags.cloexec) flags |= std.os.linux.EFD.CLOEXEC;
        if (fd_flags.nonblock) flags |= std.os.linux.EFD.NONBLOCK;
        if (opt.semaphore) flags |= std.os.linux.EFD.SEMAPHORE;
        const rc = std.os.linux.eventfd(initval, flags);
        return switch (std.os.linux.errno(rc)) {
            .SUCCESS => .{ .fd = @intCast(rc) },
            else => |e| .{ .errno = e },
        };
    }

    /// value must be below maxInt(u64). EAGAIN means the counter would
    /// overflow on a non-blocking eventfd; a blocking one waits for a read
    /// instead, and returns EINTR if a signal interrupts it.
    pub fn add(fd: std.os.linux.fd_t, value: u64) std.os.linux.E {
        if (value == std.math.maxInt(u64)) apiMisuse("eventfd add of maxInt(u64)", .{});
        const rc = std.os.linux.write(fd, std.mem.asBytes(&value), @sizeOf(u64));
        const errno = std.os.linux.errno(rc);
        if (errno == .SUCCESS) std.debug.assert(rc == @sizeOf(u64));
        return errno;
    }

    pub const TakeResult = union(enum) { value: u64, errno: std.os.linux.E };
    /// Takes the counter and resets it to zero, or with semaphore, takes 1 and
    /// decrements it. EAGAIN means the counter is
    /// zero on a non-blocking eventfd; a blocking one waits for an add
    /// instead, and returns EINTR if a signal interrupts it.
    pub fn take(fd: std.os.linux.fd_t) TakeResult {
        var value: u64 = undefined;
        const rc = std.os.linux.read(fd, std.mem.asBytes(&value), @sizeOf(u64));
        return switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                std.debug.assert(rc == @sizeOf(u64));
                return .{ .value = value };
            },
            else => |e| .{ .errno = e },
        };
    }
};

pub const SocketKind = enum {
    unix_stream,
    unix_dgram,
    unix_seqpacket,
    inet_stream,
    inet_dgram,
    inet6_stream,
    inet6_dgram,

    pub fn addressFamily(kind: SocketKind) u32 {
        return switch (kind) {
            .unix_stream, .unix_dgram, .unix_seqpacket => std.os.linux.AF.UNIX,
            .inet_stream, .inet_dgram => std.os.linux.AF.INET,
            .inet6_stream, .inet6_dgram => std.os.linux.AF.INET6,
        };
    }
    pub fn socketType(kind: SocketKind) u32 {
        return switch (kind) {
            .unix_stream, .inet_stream, .inet6_stream => std.os.linux.SOCK.STREAM,
            .unix_dgram, .inet_dgram, .inet6_dgram => std.os.linux.SOCK.DGRAM,
            .unix_seqpacket => std.os.linux.SOCK.SEQPACKET,
        };
    }
};
fn socketFlagBits(flags: FdFlags) u32 {
    var bits: u32 = 0;
    if (flags.nonblock) bits |= std.os.linux.SOCK.NONBLOCK;
    if (flags.cloexec) bits |= std.os.linux.SOCK.CLOEXEC;
    return bits;
}

/// EAFNOSUPPORT for an inet6 kind means IPv6 is disabled.
pub fn socket(kind: SocketKind, fd_flags: FdFlags) FdResult {
    const rc = std.os.linux.socket(
        kind.addressFamily(),
        kind.socketType() | socketFlagBits(fd_flags),
        0,
    );
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .fd = @intCast(rc) },
        else => |e| .{ .errno = e },
    };
}

pub fn socketpair(socket_type: enum { stream, dgram, seqpacket }, fd_flags: FdFlags) FdPairResult {
    const type_bits: u32 = switch (socket_type) {
        .stream => std.os.linux.SOCK.STREAM,
        .dgram => std.os.linux.SOCK.DGRAM,
        .seqpacket => std.os.linux.SOCK.SEQPACKET,
    };
    var fds: [2]std.os.linux.fd_t = undefined;
    return switch (std.os.linux.errno(std.os.linux.socketpair(
        std.os.linux.AF.UNIX,
        type_bits | socketFlagBits(fd_flags),
        0,
        &fds,
    ))) {
        .SUCCESS => .{ .fds = fds },
        else => |e| .{ .errno = e },
    };
}

/// Format the path straight into addr.path and set path_len to its length. A
/// path starting with a zero byte is an abstract name, which leaves no file
/// behind.
pub const UnixAddress = struct {
    addr: std.os.linux.sockaddr.un,
    path_len: usize,

    pub const max_path_len = @typeInfo(@FieldType(std.os.linux.sockaddr.un, "path")).array.len;

    /// For a path that's already a slice; path must not be empty. Returns null
    /// if it's longer than max_path_len.
    pub fn init(path: []const u8) ?UnixAddress {
        if (path.len == 0) apiMisuse("UnixAddress.init with an empty path", .{});
        if (path.len > max_path_len) return null;
        var address: UnixAddress = .{ .addr = .{ .path = @splat(0) }, .path_len = path.len };
        @memcpy(address.addr.path[0..path.len], path);
        return address;
    }

    fn sockLen(address: *const UnixAddress) std.os.linux.socklen_t {
        // the kernel autobinds a zero-length path to a random abstract name
        if (address.path_len == 0) apiMisuse("UnixAddress path_len is 0", .{});
        if (address.path_len > address.addr.path.len) apiMisuse(
            "UnixAddress path_len {} is longer than sun_path",
            .{address.path_len},
        );
        return @intCast(@offsetOf(std.os.linux.sockaddr.un, "path") + address.path_len);
    }
};
pub const SocketDomain = enum { unix, inet, inet6 };
fn SocketAddress(comptime domain: SocketDomain) type {
    return switch (domain) {
        .unix => *const UnixAddress,
        .inet => *const std.os.linux.sockaddr.in,
        .inet6 => *const std.os.linux.sockaddr.in6,
    };
}

/// EADDRINUSE means another socket has the address, or for a unix path, that a
/// file exists there, such as a socket file left by a process that exited.
/// EINVAL means fd is already bound, or the address doesn't suit the socket,
/// such as a multicast address on a stream socket or a link-local address
/// without sin6_scope_id. EAFNOSUPPORT means fd isn't a socket of the given
/// domain.
pub fn bind(
    comptime domain: SocketDomain,
    fd: std.os.linux.fd_t,
    addr: SocketAddress(domain),
) std.os.linux.E {
    return std.os.linux.errno(switch (domain) {
        .unix => std.os.linux.bind(fd, @ptrCast(&addr.addr), addr.sockLen()),
        .inet, .inet6 => std.os.linux.bind(fd, @ptrCast(addr), @sizeOf(@TypeOf(addr.*))),
    });
}

/// fd must be a bound stream or seqpacket socket.
pub fn listen(fd: std.os.linux.fd_t, backlog: u31) std.os.linux.E {
    return std.os.linux.errno(std.os.linux.listen(fd, backlog));
}

/// fd must be a listening stream or seqpacket socket. EAGAIN means a
/// non-blocking fd has no connection waiting. EINVAL means the socket was shut
/// down for reading, which is how another thread stops a blocked accept.
/// ECONNABORTED means a connection was reset before it was accepted. EMFILE or
/// ENFILE means the process or the system is out of fds, and the connection
/// stays waiting.
pub fn accept(fd: std.os.linux.fd_t, fd_flags: FdFlags) FdResult {
    const rc = std.os.linux.accept4(fd, null, null, socketFlagBits(fd_flags));
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .fd = @intCast(rc) },
        else => |e| .{ .errno = e },
    };
}

/// EINPROGRESS or EALREADY means a non-blocking connect is in progress, or
/// SO_SNDTIMEO expired with one in progress. EAGAIN means a non-blocking unix
/// socket's listener has a full backlog. After EINTR, calling connect
/// again waits for the connect already in progress (__inet_stream_connect).
pub fn connect(
    comptime domain: SocketDomain,
    fd: std.os.linux.fd_t,
    addr: SocketAddress(domain),
) std.os.linux.E {
    return std.os.linux.errno(switch (domain) {
        .unix => std.os.linux.connect(fd, @ptrCast(&addr.addr), addr.sockLen()),
        .inet, .inet6 => std.os.linux.connect(fd, @ptrCast(addr), @sizeOf(@TypeOf(addr.*))),
    });
}

/// ENOTCONN means the socket isn't connected, as after the peer resets a TCP
/// connection.
pub fn shutdown(fd: std.os.linux.fd_t, how: enum { read, write, both }) std.os.linux.E {
    const how_raw: i32 = switch (how) {
        .read => std.os.linux.SHUT.RD,
        .write => std.os.linux.SHUT.WR,
        .both => std.os.linux.SHUT.RDWR,
    };
    return std.os.linux.errno(std.os.linux.shutdown(fd, how_raw));
}

pub const SizeResult = union(enum) { size: usize, errno: std.os.linux.E };

/// A size of 0 from a stream socket means the peer closed it, unless buf is
/// empty. EAGAIN means nothing is waiting on a non-blocking fd or with
/// MSG.DONTWAIT. On a unix socket that can carry fds, use recvWithFds: a recv
/// that receives the first byte sent with fds makes the kernel close them.
pub fn recv(fd: std.os.linux.fd_t, buf: []u8, flags: u32) SizeResult {
    const rc = std.os.linux.recvfrom(fd, buf.ptr, buf.len, flags, null, null);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .size = rc },
        else => |e| .{ .errno = e },
    };
}

/// Always adds MSG.NOSIGNAL, so a closed peer returns EPIPE instead of raising
/// SIGPIPE. EAGAIN means the send buffer is full on a non-blocking fd or with
/// MSG.DONTWAIT. EPIPE or ECONNRESET means the peer closed the connection.
pub fn send(fd: std.os.linux.fd_t, buf: []const u8, flags: u32) SizeResult {
    const rc = std.os.linux.sendto(
        fd,
        buf.ptr,
        buf.len,
        flags | std.os.linux.MSG.NOSIGNAL,
        null,
        0,
    );
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .size = rc },
        else => |e| .{ .errno = e },
    };
}

/// SCM_MAX_FD: the most fds one message can carry.
pub const max_fds_per_message = 253;
const fd_size = @sizeOf(std.os.linux.fd_t);
const cmsg_header_len = cmsgAlign(@sizeOf(std.os.linux.cmsghdr));
fn cmsgAlign(size: usize) usize {
    return std.mem.alignForward(usize, size, std.os.linux.cmsg_align);
}
fn cmsgSpace(fd_count: usize) usize {
    return cmsg_header_len + cmsgAlign(fd_count * fd_size);
}
const FdsControl = [cmsgSpace(max_fds_per_message)]u8;

/// Sends data with fds attached, over a unix socket. data must not be empty,
/// since a stream socket drops fds sent without data, and fds must hold 1 to
/// max_fds_per_message open fds. The fds go with the first byte sent, so after
/// a partial send, send the rest with send. Always adds MSG.NOSIGNAL, like
/// send. ETOOMANYREFS means too many fds this user sent are still waiting to be
/// received.
pub fn sendWithFds(
    fd: std.os.linux.fd_t,
    data: []const u8,
    fds: []const std.os.linux.fd_t,
    flags: u32,
) SizeResult {
    if (data.len == 0 or fds.len == 0 or fds.len > max_fds_per_message) apiMisuse(
        "sendWithFds with {} bytes and {} fds",
        .{ data.len, fds.len },
    );
    var control: FdsControl align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const header: *std.os.linux.cmsghdr = @ptrCast(&control);
    header.* = .{
        .len = cmsg_header_len + fds.len * fd_size,
        .level = std.os.linux.SOL.SOCKET,
        .type = std.os.linux.SCM.RIGHTS,
    };
    @memcpy(control[cmsg_header_len..][0 .. fds.len * fd_size], std.mem.sliceAsBytes(fds));
    const iov: std.posix.iovec_const = .{ .base = data.ptr, .len = data.len };
    const msg: std.os.linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &control,
        .controllen = cmsgSpace(fds.len),
        .flags = 0,
    };
    const rc = std.os.linux.sendmsg(fd, &msg, flags | std.os.linux.MSG.NOSIGNAL);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .size = rc },
        else => |e| .{ .errno = e },
    };
}

pub const RecvWithFdsResult = union(enum) {
    received: struct {
        size: usize,
        /// How many fds were received into the start of fds.
        fds_count: usize,
        /// More fds were sent than fit in fds, or than RLIMIT_NOFILE allowed;
        /// the kernel closed the rest.
        fds_truncated: bool,
        /// On a seqpacket or datagram socket, the message was longer than buf;
        /// the kernel discarded the rest of it.
        data_truncated: bool,
    },
    errno: std.os.linux.E,
};
/// Receives data and the fds attached to it, over a unix socket. fds must hold
/// 1 to max_fds_per_message slots. The fds come with the first byte the sender
/// sent with them. On a stream socket, receive the rest of a partial receive
/// with recv; on a seqpacket or datagram socket, the kernel discards the rest
/// and sets data_truncated. A recv that receives that first byte drops the fds.
/// The socket must not enable other control messages (SO_PASSCRED, SO_PASSSEC,
/// timestamps): they take the space meant for fds, and the kernel closes the
/// fds that don't fit. The received fds are close-on-exec.
pub fn recvWithFds(
    fd: std.os.linux.fd_t,
    buf: []u8,
    fds: []std.os.linux.fd_t,
    flags: u32,
) RecvWithFdsResult {
    if (fds.len == 0 or fds.len > max_fds_per_message) {
        apiMisuse("recvWithFds with {} fds", .{fds.len});
    }
    var control: FdsControl align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    var iov: std.posix.iovec = .{ .base = buf.ptr, .len = buf.len };
    var msg: std.os.linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &control,
        // the kernel fits as many fds as this length holds, and the padding
        // CMSG_SPACE adds can hold one more
        .controllen = cmsg_header_len + fds.len * fd_size,
        .flags = 0,
    };
    const rc = std.os.linux.recvmsg(fd, &msg, flags | std.os.linux.MSG.CMSG_CLOEXEC);
    const size = switch (std.os.linux.errno(rc)) {
        .SUCCESS => rc,
        else => |e| return .{ .errno = e },
    };
    var fds_count: usize = 0;
    var offset: usize = 0;
    while (offset + cmsg_header_len <= msg.controllen) {
        const header: *align(1) const std.os.linux.cmsghdr = @ptrCast(&control[offset]);
        if (header.level == std.os.linux.SOL.SOCKET and header.type == std.os.linux.SCM.RIGHTS) {
            const count = (header.len - cmsg_header_len) / fd_size;
            const bytes = control[offset + cmsg_header_len ..][0 .. count * fd_size];
            @memcpy(std.mem.sliceAsBytes(fds[fds_count..][0..count]), bytes);
            fds_count += count;
        }
        offset += cmsgAlign(header.len);
    }
    return .{ .received = .{
        .size = size,
        .fds_count = fds_count,
        .fds_truncated = msg.flags & std.os.linux.MSG.CTRUNC != 0,
        .data_truncated = msg.flags & std.os.linux.MSG.TRUNC != 0,
    } };
}

pub const PollResult = union(enum) { ready: usize, errno: std.os.linux.E };
/// Returns 0 ready on timeout. EINVAL means fds.len is above RLIMIT_NOFILE,
/// which can be lowered below fds a process already has open. EINTR
/// means a signal handler ran, or the process was stopped and continued,
/// before the timeout.
pub fn poll(fds: []std.os.linux.pollfd, timeout_ms: i32) PollResult {
    const rc = std.os.linux.poll(fds.ptr, fds.len, timeout_ms);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .ready = rc },
        else => |e| .{ .errno = e },
    };
}

/// EAGAIN means a LOCK_NB request found the lock held.
pub fn flock(fd: std.os.linux.fd_t, operation: i32) std.os.linux.E {
    return std.os.linux.errno(std.os.linux.flock(fd, operation));
}

/// A file that doesn't exist counts as unlinked.
pub fn unlink(dir_fd: DirFd, path: [*:0]const u8, flags: u32) std.os.linux.E {
    while (true) switch (std.os.linux.errno(std.os.linux.unlinkat(
        @backingInt(dir_fd),
        path,
        flags,
    ))) {
        .NOENT => return .SUCCESS,
        .INTR => continue,
        else => |e| return e,
    };
}

pub const GetflResult = union(enum) { flags: std.os.linux.O, errno: std.os.linux.E };
pub fn getfl(fd: std.os.linux.fd_t) GetflResult {
    const rc = std.os.linux.fcntl(fd, std.os.linux.F.GETFL, 0);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .flags = @bitCast(@as(u32, @intCast(rc))) },
        .BADF => apiMisuse("fcntl F_GETFL fd {} returned EBADF", .{fd}),
        else => |e| .{ .errno = e },
    };
}

/// EPERM means clearing APPEND on an append-only file, or setting NOATIME on a
/// file you don't own.
pub fn setfl(fd: std.os.linux.fd_t, flags: std.os.linux.O) std.os.linux.E {
    return std.os.linux.errno(std.os.linux.fcntl(
        fd,
        std.os.linux.F.SETFL,
        @as(u32, @bitCast(flags)),
    ));
}

/// The memfd_create flags, with CLOEXEC defaulting to true like FdFlags.
pub const MemfdFlags = packed struct(u32) {
    CLOEXEC: bool = true,
    ALLOW_SEALING: bool = false,
    HUGETLB: bool = false,
    NOEXEC_SEAL: bool = false,
    EXEC: bool = false,
    _: u21 = 0,
    /// With HUGETLB, the huge page size as a power of two, 0 for the default.
    HUGE_LOG2: u6 = 0,
};
/// name must be at most 249 bytes.
pub fn memfdCreate(name: [*:0]const u8, flags: MemfdFlags) FdResult {
    const rc = std.os.linux.memfd_create(name, @bitCast(flags));
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .fd = @intCast(rc) },
        else => |e| .{ .errno = e },
    };
}

/// fd must be a regular file open for writing. Growing past RLIMIT_FSIZE also
/// sends SIGXFSZ. EPERM on a memfd means F_SEAL_GROW or F_SEAL_SHRINK.
pub fn ftruncate(fd: std.os.linux.fd_t, size: u63) std.os.linux.E {
    while (true) switch (std.os.linux.errno(std.os.linux.ftruncate(fd, size))) {
        .INTR => continue,
        else => |e| return e,
    };
}

pub const MmapKind = enum {
    /// Read/write and shared. EPERM on a memfd means F_SEAL_WRITE or
    /// F_SEAL_FUTURE_WRITE.
    shared_rw,
    /// Read-only and shared, so writes through other mappings and fds show up.
    shared_read,
    /// Read-only and private.
    private_read,
};
pub const MmapSharedRwResult = union(enum) {
    mapped: []align(std.heap.page_size_min) u8,
    errno: std.os.linux.E,
};
pub const MmapReadResult = union(enum) {
    mapped: []align(std.heap.page_size_min) const u8,
    errno: std.os.linux.E,
};
/// Maps the first `size` bytes of fd. size must not be zero, and for a hugetlb
/// file must be a multiple of the huge page size, or munmap can't unmap the
/// slice. Touching pages past the end of the file raises SIGBUS.
pub fn mmap(comptime kind: MmapKind, fd: std.os.linux.fd_t, size: usize) switch (kind) {
    .shared_rw => MmapSharedRwResult,
    .shared_read, .private_read => MmapReadResult,
} {
    const rc = std.os.linux.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = kind == .shared_rw },
        .{ .TYPE = if (kind == .private_read) .PRIVATE else .SHARED },
        fd,
        0,
    );
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{
            .mapped = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(rc))[0..size],
        },
        else => |e| .{ .errno = e },
    };
}

pub const FileSizeResult = union(enum) {
    size: u64,
    errno: std.os.linux.E,
};
pub fn fileSize(fd: std.os.linux.fd_t) FileSizeResult {
    var statx: std.os.linux.Statx = undefined;
    while (true) return switch (std.os.linux.errno(std.os.linux.statx(
        fd,
        "",
        std.os.linux.AT.EMPTY_PATH,
        .{ .SIZE = true },
        &statx,
    ))) {
        .SUCCESS => .{ .size = statx.size },
        .INTR => continue,
        else => |e| .{ .errno = e },
    };
}

/// memory must be a whole mapping returned by mmap.
pub fn munmap(memory: []align(std.heap.page_size_min) const u8) void {
    switch (std.os.linux.errno(std.os.linux.munmap(memory.ptr, memory.len))) {
        .SUCCESS => {},
        .INVAL => apiMisuse("munmap {*} len {} returned EINVAL", .{ memory.ptr, memory.len }),
        else => |e| panicUnexpectedErrno("munmap", e),
    }
}

/// Sleeps the whole duration; a signal handler that runs doesn't cut it short.
pub fn nanosleep(ns: u64) void {
    var remaining: std.os.linux.timespec = .{
        .sec = @intCast(@min(
            ns / std.time.ns_per_s,
            std.math.maxInt(@FieldType(std.os.linux.timespec, "sec")),
        )),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    while (true) switch (std.os.linux.errno(std.os.linux.nanosleep(&remaining, &remaining))) {
        .SUCCESS => return,
        .INTR => {},
        else => |e| panicUnexpectedErrno("nanosleep", e),
    };
}

/// Reads one of the clocks that can't fail. The alarm clocks fail without an
/// alarm-capable RTC, so they don't compile.
pub fn clockGettime(comptime clock: std.os.linux.clockid_t) std.Io.Timestamp {
    switch (clock) {
        .REALTIME,
        .MONOTONIC,
        .PROCESS_CPUTIME_ID,
        .THREAD_CPUTIME_ID,
        .MONOTONIC_RAW,
        .REALTIME_COARSE,
        .MONOTONIC_COARSE,
        .BOOTTIME,
        // CLOCK_TAI, which std leaves unnamed
        @as(std.os.linux.clockid_t, @fromBackingInt(@intCast(11))),
        => {},
        else => @compileError(std.fmt.comptimePrint("clock {d} can fail", .{@backingInt(clock)})),
    }
    var ts: std.os.linux.timespec = undefined;
    switch (std.os.linux.errno(std.os.linux.clock_gettime(clock, &ts))) {
        .SUCCESS => return .fromNanoseconds(@as(i96, ts.sec) * std.time.ns_per_s + ts.nsec),
        else => |e| panicUnexpectedErrno("clock_gettime", e),
    }
}

/// A reading, in nanoseconds, of a clock that never goes backwards, so readings
/// of the same clock compare in the order they were taken.
pub fn MonoInstant(comptime clock: std.os.linux.clockid_t) type {
    switch (clock) {
        .MONOTONIC, .MONOTONIC_RAW, .BOOTTIME => {},
        else => @compileError("clock " ++ @tagName(clock) ++ " can go backwards"),
    }
    return struct {
        ns: u64,

        pub fn now() @This() {
            return .{ .ns = @intCast(clockGettime(clock).nanoseconds) };
        }
        pub fn addNs(self: @This(), ns: u64) @This() {
            return .{ .ns = self.ns + ns };
        }
        pub fn order(self: @This(), other: @This()) std.math.Order {
            return std.math.order(self.ns, other.ns);
        }
        /// `later` must not be earlier than `self`.
        pub fn elapsedNs(self: @This(), later: @This()) u64 {
            return later.ns - self.ns;
        }
    };
}

/// Fills buf, waiting for the kernel's entropy pool to initialize if it hasn't.
/// ENOSYS means Linux before 3.17.
pub fn getrandom(buf: []u8) std.os.linux.E {
    var filled: usize = 0;
    while (filled < buf.len) {
        const rc = std.os.linux.getrandom(buf[filled..].ptr, buf.len - filled, 0);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => filled += rc,
            .INTR => {},
            .FAULT, .INVAL => |e| apiMisuse("getrandom returned errno {d}", .{e}),
            else => |e| return e,
        }
    }
    return .SUCCESS;
}

/// The algorithm of std.Io.Mutex, waiting with the futex syscall instead of an Io.
pub const Mutex = struct {
    state: std.atomic.Value(State) = .init(.unlocked),

    const State = enum(u32) { unlocked, locked_once, contended };

    pub fn lock(m: *Mutex) void {
        const initial = m.state.cmpxchgStrong(
            .unlocked,
            .locked_once,
            .acquire,
            .monotonic,
        ) orelse return;
        if (initial == .contended) m.wait();
        while (m.state.swap(.contended, .acquire) != .unlocked) m.wait();
    }

    pub fn unlock(m: *Mutex) void {
        switch (m.state.swap(.unlocked, .release)) {
            .unlocked => apiMisuse("unlock of an unlocked mutex", .{}),
            .locked_once => {},
            .contended => switch (std.os.linux.errno(std.os.linux.futex_3arg(
                &m.state.raw,
                .{ .cmd = .WAKE, .private = true },
                1,
            ))) {
                // After the swap, another thread can lock, unlock and free the
                // mutex. If its memory is reused by a PI futex with waiters,
                // the wake returns EINVAL (futex_wake in kernel/futex/waitwake.c).
                .SUCCESS, .INVAL => {},
                else => |e| panicUnexpectedErrno("futex wake", e),
            },
        }
    }

    fn wait(m: *Mutex) void {
        const rc = std.os.linux.futex_4arg(
            &m.state.raw,
            .{ .cmd = .WAIT, .private = true },
            @backingInt(State.contended),
            null,
        );
        switch (std.os.linux.errno(rc)) {
            // like pthread_mutex_lock, a signal handler can't interrupt a lock
            .SUCCESS, .INTR, .AGAIN => {},
            else => |e| panicUnexpectedErrno("futex wait", e),
        }
    }
};

/// Names the calling thread; the kernel truncates name to 15 bytes. A seccomp
/// filter can make it fail.
pub fn setThreadName(name: [*:0]const u8) std.os.linux.E {
    return std.os.linux.errno(std.os.linux.prctl(
        @backingInt(std.os.linux.PR.SET_NAME),
        @intFromPtr(name),
        0,
        0,
        0,
    ));
}

/// Reads what's available, up to buf.len bytes. A size of 0 for a non-empty
/// buf means the file ended. EAGAIN means a non-blocking fd has nothing to
/// read.
pub fn read(fd: std.os.linux.fd_t, buf: []u8) SizeResult {
    const rc = std.os.linux.read(fd, buf.ptr, buf.len);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .size = rc },
        else => |e| .{ .errno = e },
    };
}

/// Writes what fits, up to bytes.len bytes. EAGAIN means a non-blocking fd has
/// no room. A broken pipe raises SIGPIPE, which kills the process unless
/// ignored.
pub fn write(fd: std.os.linux.fd_t, bytes: []const u8) SizeResult {
    const rc = std.os.linux.write(fd, bytes.ptr, bytes.len);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => .{ .size = rc },
        else => |e| .{ .errno = e },
    };
}

pub const ReadAllResult = union(enum) {
    full,
    /// The file ended after this many bytes, before buf was full.
    eof: usize,
    fail: struct { read: usize, errno: std.os.linux.E },
};
/// Reads until buf is full, the file ends, or a read fails.
pub fn readAll(fd: std.os.linux.fd_t, buf: []u8) ReadAllResult {
    var len: usize = 0;
    while (len < buf.len) {
        const rc = std.os.linux.read(fd, buf[len..].ptr, buf.len - len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return .{ .eof = len };
                len += rc;
            },
            else => |e| return .{ .fail = .{ .read = len, .errno = e } },
        }
    }
    return .full;
}

/// Reads from offset until buf is full, the file ends, or a read fails.
pub fn preadAll(fd: std.os.linux.fd_t, buf: []u8, offset: u63) ReadAllResult {
    var len: usize = 0;
    while (len < buf.len) {
        const rc = std.os.linux.pread(fd, buf[len..].ptr, buf.len - len, @intCast(offset + len));
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return .{ .eof = len };
                len += rc;
            },
            else => |e| return .{ .fail = .{ .read = len, .errno = e } },
        }
    }
    return .full;
}

/// A write of a non-empty buffer that writes nothing and reports no errno can't
/// make progress. Like panicUnexpectedErrno, it panics in every build mode.
fn panicZeroWrite(fd: std.os.linux.fd_t, size: usize) noreturn {
    std.debug.panic("write fd {} returned 0 for {} bytes", .{ fd, size });
}

/// How much of the bytes writeAll wrote before a write failed.
pub const WriteIncomplete = struct { written: usize, errno: std.os.linux.E };
/// Writes all of bytes, retrying partial writes. Returns null once they're all
/// written. A broken pipe raises SIGPIPE, which kills the process unless
/// ignored.
pub fn writeAll(fd: std.os.linux.fd_t, bytes: []const u8) ?WriteIncomplete {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.os.linux.write(fd, bytes[written..].ptr, bytes.len - written);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) panicZeroWrite(fd, bytes.len - written);
                written += rc;
            },
            else => |e| return .{ .written = written, .errno = e },
        }
    }
    return null;
}

/// A std.Io.Writer that drains with one writev of the buffer, data and splat,
/// like std's streaming file writer. A broken pipe raises SIGPIPE, which kills
/// the process unless ignored.
pub const FdWriter = struct {
    fd: std.os.linux.fd_t,
    /// The errno behind the last error.WriteFailed.
    errno: std.os.linux.E = undefined,
    interface: std.Io.Writer,

    pub fn init(fd: std.os.linux.fd_t, buffer: []u8) FdWriter {
        return .{ .fd = fd, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
        const self: *FdWriter = @alignCast(@fieldParentPtr("interface", w));
        var iovecs: Iovecs = .{};
        iovecs.add(w.buffered());
        for (data[0 .. data.len - 1]) |bytes| iovecs.add(bytes);
        const pattern = data[data.len - 1];
        var splat_buf: [64]u8 = undefined;
        if (pattern.len == 1 and splat > 1) {
            @memset(&splat_buf, pattern[0]);
            var remaining = splat;
            while (remaining > 0 and !iovecs.full()) {
                const len = @min(remaining, splat_buf.len);
                iovecs.add(splat_buf[0..len]);
                remaining -= len;
            }
        } else for (0..splat) |_| {
            if (iovecs.full()) break;
            iovecs.add(pattern);
        }
        if (iovecs.count == 0) return 0;
        const rc = std.os.linux.writev(self.fd, &iovecs.buf, iovecs.count);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) panicZeroWrite(self.fd, iovecs.totalSize());
                return w.consume(rc);
            },
            else => |e| {
                self.errno = e;
                return error.WriteFailed;
            },
        }
    }

    const Iovecs = struct {
        buf: [8]std.posix.iovec_const = undefined,
        count: usize = 0,
        fn totalSize(v: *const Iovecs) usize {
            var size: usize = 0;
            for (v.buf[0..v.count]) |iovec| size += iovec.len;
            return size;
        }
        fn full(v: *const Iovecs) bool {
            return v.count == v.buf.len;
        }
        fn add(v: *Iovecs, bytes: []const u8) void {
            // the kernel checks the address even for zero length
            if (bytes.len == 0 or v.full()) return;
            v.buf[v.count] = .{ .base = bytes.ptr, .len = bytes.len };
            v.count += 1;
        }
    };
};

/// A std.Io.Reader over a byte stream, such as a pipe, stream socket or tty.
/// A datagram socket doesn't fit: an empty datagram would read as the end of
/// the stream. Each read fills as many of the caller's slices as one readv
/// takes, with what's left over going into the buffer.
pub const FdReader = struct {
    fd: std.os.linux.fd_t,
    /// The errno behind the last error.ReadFailed.
    errno: std.os.linux.E = undefined,
    interface: std.Io.Reader,

    pub fn init(fd: std.os.linux.fd_t, buffer: []u8) FdReader {
        return .{ .fd = fd, .interface = .{
            .vtable = &.{ .stream = stream, .readVec = readVec, .discard = discard },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        } };
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        var data: [1][]u8 = .{limit.slice(try w.writableSliceGreedy(1))};
        const size = try readVec(r, &data);
        w.advance(size);
        return size;
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *FdReader = @alignCast(@fieldParentPtr("interface", r));
        var iovecs: [16]std.posix.iovec = undefined;
        // writableVectorPosix adds the buffer after data without checking for
        // room, so leave it a slot
        const iovec_count, const data_size = try r.writableVectorPosix(
            &iovecs,
            data[0..@min(data.len, iovecs.len - 1)],
        );
        var capacity: usize = 0;
        for (iovecs[0..iovec_count]) |iovec| capacity += iovec.len;
        // a read into nothing returns 0, which would look like the end
        if (capacity == 0) return 0;
        const rc = std.os.linux.readv(self.fd, &iovecs, iovec_count);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.EndOfStream;
                if (rc > data_size) {
                    r.end += rc - data_size;
                    return data_size;
                }
                return rc;
            },
            else => |e| {
                self.errno = e;
                return error.ReadFailed;
            },
        }
    }

    // The default discard reads through the buffer, so it can't work without
    // one.
    fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *FdReader = @alignCast(@fieldParentPtr("interface", r));
        var scratch: [4096]u8 = undefined;
        const dest = limit.slice(&scratch);
        if (dest.len == 0) return 0;
        const rc = std.os.linux.read(self.fd, dest.ptr, dest.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.EndOfStream;
                return rc;
            },
            else => |e| {
                self.errno = e;
                return error.ReadFailed;
            },
        }
    }
};

/// Creates path and any missing parent directories, like mkdir -p. EEXIST
/// counts as success even when path is a file rather than a directory.
pub fn makePath(dir_fd: DirFd, path: []const u8) std.os.linux.E {
    var buf: [std.os.linux.PATH_MAX:0]u8 = undefined;
    if (path.len >= buf.len) return .NAMETOOLONG;
    @memcpy(buf[0..path.len], path);
    var end = path.len;
    while (true) {
        buf[end] = 0;
        switch (mkdir(dir_fd, buf[0..end :0])) {
            .SUCCESS, .EXIST => break,
            .NOENT => end = std.mem.lastIndexOfScalar(u8, buf[0..end], '/') orelse return .NOENT,
            else => |e| return e,
        }
        if (end == 0) return .NOENT;
    }
    while (end < path.len) {
        buf[end] = '/';
        end = std.mem.indexOfScalarPos(u8, path, end + 1, '/') orelse path.len;
        buf[end] = 0;
        switch (mkdir(dir_fd, buf[0..end :0])) {
            .SUCCESS, .EXIST => {},
            else => |e| return e,
        }
    }
    return .SUCCESS;
}
fn mkdir(dir_fd: DirFd, path: [*:0]const u8) std.os.linux.E {
    while (true) switch (std.os.linux.errno(std.os.linux.mkdirat(
        @backingInt(dir_fd),
        path,
        0o755,
    ))) {
        .INTR => {},
        else => |e| return e,
    };
}

/// Iterates a directory opened with O.DIRECTORY, skipping "." and "..".
pub const DirIterator = struct {
    fd: std.os.linux.fd_t,
    buf: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined,
    index: usize = 0,
    end: usize = 0,

    pub const Entry = struct {
        /// Valid until the next call to next.
        name: [:0]const u8,
        /// One of std.os.linux.DT; DT.UNKNOWN on filesystems that don't report it.
        type: u8,
    };

    pub fn next(it: *DirIterator) union(enum) { entry: Entry, end, errno: std.os.linux.E } {
        while (true) {
            if (it.index == it.end) {
                const rc = std.os.linux.getdents64(it.fd, &it.buf, it.buf.len);
                switch (std.os.linux.errno(rc)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => |e| return .{ .errno = e },
                }
                if (rc == 0) return .end;
                it.index = 0;
                it.end = rc;
            }
            const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&it.buf[it.index]);
            it.index += entry.reclen;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return .{ .entry = .{ .name = name, .type = entry.type } };
        }
    }
};

/// Signals thread tid of this process; it uses tgkill, so a tid reused by
/// another process isn't signaled. tid must be positive and sig a valid
/// signal. ESRCH means no thread of this process has tid, such as after the
/// thread exited. Once it exits, a new thread of this process can reuse tid.
pub fn tkill(tid: std.os.linux.pid_t, sig: std.os.linux.SIG) std.os.linux.E {
    return switch (std.os.linux.errno(std.os.linux.tgkill(std.os.linux.getpid(), tid, sig))) {
        .INVAL => apiMisuse("tgkill tid {} sig {} returned EINVAL", .{ tid, @backingInt(sig) }),
        else => |e| e,
    };
}

const std = @import("std");
