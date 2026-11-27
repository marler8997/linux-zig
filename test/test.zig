test "every declaration compiles" {
    std.testing.refAllDecls(linux);
    std.testing.refAllDecls(linux.epoll);
    std.testing.refAllDecls(linux.eventfd);
    std.testing.refAllDecls(linux.FileSync);
    std.testing.refAllDecls(linux.Mutex);
    std.testing.refAllDecls(linux.FdWriter);
    std.testing.refAllDecls(linux.FdReader);
    std.testing.refAllDecls(linux.DirIterator);
    std.testing.refAllDecls(linux.MonoInstant(.MONOTONIC));
}

fn testIsOpen(fd: std.os.linux.fd_t) bool {
    return switch (std.os.linux.errno(std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0))) {
        .SUCCESS => true,
        .BADF => false,
        else => |e| std.debug.panic("fcntl F_GETFD returned unexpected errno {d}", .{e}),
    };
}
fn testIsCloexec(fd: std.os.linux.fd_t) bool {
    const rc = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
    std.debug.assert(std.os.linux.errno(rc) == .SUCCESS);
    return rc & std.os.linux.FD_CLOEXEC != 0;
}
fn testFd(result: linux.FdResult) std.os.linux.fd_t {
    return switch (result) {
        .fd => |fd| fd,
        .errno => |e| std.debug.panic("errno {d}", .{e}),
    };
}
fn testFds(result: linux.FdPairResult) [2]std.os.linux.fd_t {
    return switch (result) {
        .fds => |fds| fds,
        .errno => |e| std.debug.panic("errno {d}", .{e}),
    };
}
fn testSize(result: linux.SizeResult) usize {
    return switch (result) {
        .size => |size| size,
        .errno => |e| std.debug.panic("errno {d}", .{e}),
    };
}
fn expectSuccess(errno: std.os.linux.E) !void {
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, errno);
}
fn testWriteAll(fd: std.os.linux.fd_t, bytes: []const u8) !void {
    try std.testing.expectEqual(@as(?linux.WriteIncomplete, null), linux.writeAll(fd, bytes));
}
fn testWait(pid: std.os.linux.pid_t) !u32 {
    const status = switch (linux.waitpid(.block, pid)) {
        .status => |status| status,
        .errno => |e| std.debug.panic("waitpid errno {d}", .{e}),
    };
    try std.testing.expect(std.os.linux.W.IFEXITED(status));
    return std.os.linux.W.EXITSTATUS(status);
}
fn testMemfd(flags: linux.MemfdFlags) std.os.linux.fd_t {
    return testFd(linux.memfdCreate("linux-zig-test", flags));
}

fn testMemfdBits(flags: linux.MemfdFlags) u32 {
    return @bitCast(flags);
}
test "MemfdFlags matches the kernel's flag bits" {
    const bits = std.os.linux.MFD;
    try std.testing.expectEqual(bits.CLOEXEC, testMemfdBits(.{}));
    try std.testing.expectEqual(
        bits.ALLOW_SEALING,
        testMemfdBits(.{ .CLOEXEC = false, .ALLOW_SEALING = true }),
    );
    try std.testing.expectEqual(
        bits.HUGETLB,
        testMemfdBits(.{ .CLOEXEC = false, .HUGETLB = true }),
    );
    // std has no MFD.NOEXEC_SEAL or MFD.EXEC; these are from linux/memfd.h
    try std.testing.expectEqual(
        @as(u32, 0x8),
        testMemfdBits(.{ .CLOEXEC = false, .NOEXEC_SEAL = true }),
    );
    try std.testing.expectEqual(@as(u32, 0x10), testMemfdBits(.{ .CLOEXEC = false, .EXEC = true }));
    try std.testing.expectEqual(
        bits.HUGE_2MB,
        testMemfdBits(.{ .CLOEXEC = false, .HUGE_LOG2 = 21 }),
    );
}

test "CloseKind has a declaration for every FdKind" {
    inline for (@typeInfo(linux.FdKind).@"enum".field_names) |name| {
        try std.testing.expectEqual(
            linux.CloseKind.fromFdKind(@field(linux.FdKind, name)),
            @field(linux.CloseKind, name),
        );
    }
}

test "close a kernel object without a flush operation" {
    for (testFds(linux.socketpair(.stream, .{}))) |fd| {
        linux.close(.socket, fd);
        try std.testing.expect(!testIsOpen(fd));
    }
    {
        const fd = testFd(
            linux.open(undefined, "/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0),
        );
        linux.close(.tty, fd);
        try std.testing.expect(!testIsOpen(fd));
    }
    for (testFds(linux.pipe2(.{}))) |fd| {
        linux.close(.pipe, fd);
        try std.testing.expect(!testIsOpen(fd));
    }
    {
        const fd = testFd(linux.epoll.create(.{}));
        linux.close(.epoll, fd);
        try std.testing.expect(!testIsOpen(fd));
    }
    {
        const fd = testFd(linux.eventfd.create(0, .{}, .{}));
        linux.close(.eventfd, fd);
        try std.testing.expect(!testIsOpen(fd));
    }
    {
        const fd = testMemfd(.{});
        linux.close(.memfd, fd);
        try std.testing.expect(!testIsOpen(fd));
    }
    {
        const fd = testFd(linux.open(undefined, "/dev/null", .{ .ACCMODE = .RDONLY }, 0));
        linux.close(.dev_null, fd);
        try std.testing.expect(!testIsOpen(fd));
    }
    {
        const fd = testFd(linux.open(undefined, "/", .{ .ACCMODE = .RDONLY, .PATH = true }, 0));
        linux.close(.o_path, fd);
        try std.testing.expect(!testIsOpen(fd));
    }
}

test "close a file whose writes don't have to reach storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "log", .data = "line\n" });

    const fd = testFd(
        linux.open(.fromFd(tmp.dir.handle), "log", .{ .ACCMODE = .WRONLY, .APPEND = true }, 0),
    );
    try testWriteAll(fd, "another line\n");
    linux.close(.ignore_flush_error, fd);
    try std.testing.expect(!testIsOpen(fd));

    const read_fd = testFd(linux.open(.fromFd(tmp.dir.handle), "log", .{ .ACCMODE = .RDONLY }, 0));
    try expectSuccess(linux.close(.any, read_fd));
    try std.testing.expect(!testIsOpen(read_fd));
}

test "exec a program found on PATH" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "noexec", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "noexec/prog",
        .data = "#!/bin/sh\nexit 1\n",
        .flags = .{ .permissions = .fromMode(0o644) },
    });
    try tmp.dir.createDir(std.testing.io, "bin", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "bin/prog",
        .data = "#!/bin/sh\nexit 7\n",
        .flags = .{ .permissions = .fromMode(0o755) },
    });

    const dir = ".zig-cache/tmp/" ++ tmp.sub_path;
    const argv = [_:null]?[*:0]const u8{ "prog", null };
    const envp = [_:null]?[*:0]const u8{null};
    // skips a missing directory and one where prog isn't executable
    const path_list = dir ++ "/missing:" ++ dir ++ "/noexec:" ++ dir ++ "/bin";

    // failures return without exec, so they can run in this process
    try std.testing.expectEqual(std.os.linux.E.ACCES, linux.execve(
        .search,
        .{ .file = "prog", .path_list = dir ++ "/missing:" ++ dir ++ "/noexec" },
        &argv,
        &envp,
    ));
    try std.testing.expectEqual(std.os.linux.E.NOENT, linux.execve(
        .search,
        .{ .file = "", .path_list = path_list },
        &argv,
        &envp,
    ));
    // a name with a '/' isn't looked up
    try std.testing.expectEqual(
        std.os.linux.E.NOENT,
        linux.execve(.search, .{ .file = "./prog", .path_list = path_list }, &argv, &envp),
    );

    switch (linux.fork()) {
        .child => std.os.linux.exit_group(100 + @as(i32, @backingInt(linux.execve(
            .search,
            .{ .file = "prog", .path_list = path_list },
            &argv,
            &envp,
        )))),
        .parent => |pid| try std.testing.expectEqual(@as(u32, 7), try testWait(pid)),
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    }

    // an empty entry doesn't mean the cwd, even when the cwd has prog
    switch (linux.fork()) {
        .child => {
            if (linux.chdir(dir ++ "/bin") != .SUCCESS) std.os.linux.exit_group(99);
            std.os.linux.exit_group(100 + @as(i32, @backingInt(linux.execve(
                .search,
                .{ .file = "prog", .path_list = "/nonexistent::/nonexistent" },
                &argv,
                &envp,
            ))));
        },
        .parent => |pid| try std.testing.expectEqual(
            @as(u32, 100 + @backingInt(std.os.linux.E.NOENT)),
            try testWait(pid),
        ),
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    }
}

test "exec a memfd" {
    const memfd = testFd(linux.memfdCreate("linux-zig-test", .{ .CLOEXEC = false }));
    defer linux.close(.memfd, memfd);
    try testWriteAll(memfd, "#!/bin/sh\nexit 5\n");
    const argv = [_:null]?[*:0]const u8{ "linux-zig-test", null };
    const envp = [_:null]?[*:0]const u8{null};
    switch (linux.fork()) {
        .child => std.os.linux.exit_group(100 + @as(i32, @backingInt(linux.execve(
            .fd,
            memfd,
            &argv,
            &envp,
        )))),
        .parent => |pid| switch (try testWait(pid)) {
            5 => {},
            // vm.memfd_noexec forbids executing memfds
            100 + @backingInt(std.os.linux.E.ACCES) => return error.SkipZigTest,
            else => |status| std.debug.panic("exit status {d}", .{status}),
        },
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    }
}

test "a duplicated fd isn't inherited across exec" {
    const memfd = testMemfd(.{});
    defer linux.close(.memfd, memfd);
    const dup_fd = testFd(linux.dup(memfd, .{}));
    defer linux.close(.memfd, dup_fd);
    const rc = std.os.linux.fcntl(dup_fd, std.os.linux.F.GETFD, 0);
    try expectSuccess(std.os.linux.errno(rc));
    try std.testing.expectEqual(@as(usize, std.os.linux.FD_CLOEXEC), rc & std.os.linux.FD_CLOEXEC);
}

test "dup2 leaves the target inheritable" {
    const memfd = testMemfd(.{});
    defer linux.close(.memfd, memfd);
    try std.testing.expect(testIsCloexec(memfd));
    // onto the same fd, which the syscall would leave close-on-exec
    try expectSuccess(linux.dup2(memfd, memfd));
    try std.testing.expect(!testIsCloexec(memfd));

    const other = testMemfd(.{});
    defer linux.close(.memfd, other);
    try expectSuccess(linux.dup2(memfd, other));
    try std.testing.expect(!testIsCloexec(other));
}

test "seals on a memfd" {
    const memfd = testMemfd(.{ .ALLOW_SEALING = true });
    defer linux.close(.memfd, memfd);
    try expectSuccess(linux.ftruncate(memfd, 4096));
    const mapped = switch (linux.mmap(.shared_rw, memfd, 4096)) {
        .mapped => |mapped| mapped,
        .errno => |e| std.debug.panic("mmap errno {d}", .{e}),
    };
    mapped[0] = 1;
    linux.munmap(mapped);
    try expectSuccess(std.os.linux.errno(std.os.linux.fcntl(
        memfd,
        std.os.linux.F.ADD_SEALS,
        std.os.linux.F.SEAL_GROW | std.os.linux.F.SEAL_WRITE,
    )));
    try std.testing.expectEqual(std.os.linux.E.PERM, linux.ftruncate(memfd, 8192));
    try std.testing.expectEqual(
        linux.MmapSharedRwResult{ .errno = .PERM },
        linux.mmap(.shared_rw, memfd, 4096),
    );
    // a write seal doesn't stop a read-only mapping
    switch (linux.mmap(.shared_read, memfd, 4096)) {
        .mapped => |read_only| {
            try std.testing.expectEqual(@as(u8, 1), read_only[0]);
            linux.munmap(read_only);
        },
        .errno => |e| std.debug.panic("mmap errno {d}", .{e}),
    }
}

test "a shared read-only mapping sees writes" {
    const memfd = testMemfd(.{});
    defer linux.close(.memfd, memfd);
    try expectSuccess(linux.ftruncate(memfd, 4096));
    const read_only = switch (linux.mmap(.shared_read, memfd, 4096)) {
        .mapped => |mapped| mapped,
        .errno => |e| std.debug.panic("mmap errno {d}", .{e}),
    };
    defer linux.munmap(read_only);
    const writable = switch (linux.mmap(.shared_rw, memfd, 4096)) {
        .mapped => |mapped| mapped,
        .errno => |e| std.debug.panic("mmap errno {d}", .{e}),
    };
    defer linux.munmap(writable);
    writable[100] = 42;
    try std.testing.expectEqual(@as(u8, 42), read_only[100]);
}

test "open the std fds a process started without" {
    switch (linux.fork()) {
        .child => {
            linux.close(.ignore_flush_error, 1);
            linux.close(.ignore_flush_error, 2);
            if (linux.openStdFds() != .SUCCESS) std.os.linux.exit_group(1);
            if (!testIsOpen(1) or !testIsOpen(2)) std.os.linux.exit_group(2);
            // the next open no longer lands on a std fd
            const fd = switch (linux.open(undefined, "/dev/null", .{ .ACCMODE = .RDONLY }, 0)) {
                .fd => |fd| fd,
                .errno => std.os.linux.exit_group(3),
            };
            std.os.linux.exit_group(if (fd > 2) 0 else 4);
        },
        .parent => |pid| try std.testing.expectEqual(@as(u32, 0), try testWait(pid)),
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    }
}

test "close every fd in a range" {
    // each open takes the lowest free fd, so fds ascend
    var fds: [6]std.os.linux.fd_t = undefined;
    for (&fds) |*slot| {
        slot.* = testFd(linux.open(undefined, "/dev/null", .{ .ACCMODE = .RDONLY }, 0));
    }
    // a gap in the range
    linux.close(.dev_null, fds[2]);

    try expectSuccess(linux.closeRange(fds[1], fds[4]));
    for (fds[1..5]) |fd| try std.testing.expect(!testIsOpen(fd));
    try std.testing.expect(testIsOpen(fds[0]));
    try std.testing.expect(testIsOpen(fds[5]));
    linux.close(.dev_null, fds[0]);
    linux.close(.dev_null, fds[5]);
}

test "save a file's contents to storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fd = testFd(
        linux.open(.fromFd(tmp.dir.handle), "saved", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644),
    );
    var file_sync: linux.FileSync = .{};
    defer file_sync.cancel(fd);
    try testWriteAll(fd, "contents");
    try std.testing.expect(file_sync.syncClose(fd) == null);
    try std.testing.expect(!testIsOpen(fd));

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings(
        "contents",
        try tmp.dir.readFile(std.testing.io, "saved", &buf),
    );

    // the deferred cancel must not close the fd number again once something
    // else reuses it
    const reused = testFd(linux.open(undefined, "/dev/null", .{ .ACCMODE = .RDONLY }, 0));
    try std.testing.expectEqual(fd, reused);
    file_sync.cancel(fd);
    try std.testing.expect(testIsOpen(reused));
    linux.close(.dev_null, reused);
}

test "abandon or fail saving a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fd = testFd(
        linux.open(
            .fromFd(tmp.dir.handle),
            "abandoned",
            .{ .ACCMODE = .WRONLY, .CREAT = true },
            0o644,
        ),
    );
    {
        var file_sync: linux.FileSync = .{};
        defer file_sync.cancel(fd);
        try testWriteAll(fd, "partial");
        // an error here returns before syncClose
    }
    try std.testing.expect(!testIsOpen(fd));

    // fsync fails: a pipe has no storage to sync to
    const pipe = testFds(linux.pipe2(.{}));
    defer linux.close(.pipe, pipe[0]);
    {
        var file_sync: linux.FileSync = .{};
        defer file_sync.cancel(pipe[1]);
        const failure = file_sync.syncClose(pipe[1]).?;
        try std.testing.expectEqual(
            linux.FileSync.SyncCloseFailure{ .op = .fsync, .errno = .INVAL },
            failure,
        );
        try std.testing.expectFmt("fsync failed, errno 22", "{f}", .{failure});
    }
    try std.testing.expect(!testIsOpen(pipe[1]));
}

test "poll a pipe" {
    const pipe = testFds(linux.pipe2(.{}));
    defer for (pipe) |fd| linux.close(.pipe, fd);
    var fds = [_]std.os.linux.pollfd{.{
        .fd = pipe[0],
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(linux.PollResult{ .ready = 0 }, linux.poll(&fds, 0));
    try testWriteAll(pipe[1], "x");
    try std.testing.expectEqual(linux.PollResult{ .ready = 1 }, linux.poll(&fds, -1));
    try std.testing.expect(fds[0].revents & std.os.linux.POLL.IN != 0);
}

test "send and receive on a socketpair" {
    const pair = testFds(linux.socketpair(.stream, .{}));
    defer linux.close(.socket, pair[0]);
    try std.testing.expectEqual(@as(usize, 2), testSize(linux.send(pair[0], "hi", 0)));
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("hi", buf[0..testSize(linux.recv(pair[1], &buf, 0))]);
    try std.testing.expectEqual(
        linux.SizeResult{ .errno = .AGAIN },
        linux.recv(pair[1], &buf, std.os.linux.MSG.DONTWAIT),
    );
    linux.close(.socket, pair[1]);
    // the peer closed
    try std.testing.expectEqual(@as(usize, 0), testSize(linux.recv(pair[0], &buf, 0)));
    try std.testing.expectEqual(
        linux.SizeResult{ .errno = .PIPE },
        linux.send(pair[0], "hi", 0),
    );
}

test "pass fds over a socketpair" {
    const pair = testFds(linux.socketpair(.stream, .{}));
    defer for (pair) |fd| linux.close(.socket, fd);
    const pipe = testFds(linux.pipe2(.{}));
    defer for (pipe) |fd| linux.close(.pipe, fd);

    try std.testing.expectEqual(@as(usize, 1), testSize(linux.sendWithFds(pair[0], "x", &pipe, 0)));
    var buf: [8]u8 = undefined;
    var fds: [2]std.os.linux.fd_t = undefined;
    const received = switch (linux.recvWithFds(
        pair[1],
        &buf,
        &fds,
        0,
    )) {
        .received => |r| r,
        .errno => |e| std.debug.panic("recvWithFds errno {d}", .{e}),
    };
    try std.testing.expectEqual(@as(usize, 1), received.size);
    try std.testing.expectEqual(@as(usize, 2), received.fds_count);
    try std.testing.expect(!received.fds_truncated);
    try std.testing.expect(!received.data_truncated);
    for (fds) |fd| try std.testing.expect(testIsCloexec(fd));
    defer for (fds) |fd| linux.close(.pipe, fd);
    // the received write end writes into the same pipe
    try testWriteAll(fds[1], "y");
    try std.testing.expectEqual(linux.ReadAllResult.full, linux.readAll(pipe[0], buf[0..1]));
    try std.testing.expectEqual(@as(u8, 'y'), buf[0]);

    // fds that don't fit are closed and reported
    try std.testing.expectEqual(@as(usize, 1), testSize(linux.sendWithFds(pair[0], "x", &pipe, 0)));
    var one_fd: [1]std.os.linux.fd_t = undefined;
    const truncated = switch (linux.recvWithFds(
        pair[1],
        &buf,
        &one_fd,
        0,
    )) {
        .received => |r| r,
        .errno => |e| std.debug.panic("recvWithFds errno {d}", .{e}),
    };
    try std.testing.expectEqual(@as(usize, 1), truncated.fds_count);
    try std.testing.expect(truncated.fds_truncated);
    linux.close(.pipe, one_fd[0]);
}

test "make a path and read a symlink relative to a directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir: linux.DirFd = .fromFd(tmp.dir.handle);
    try expectSuccess(linux.makePath(dir, "a/b/c"));
    // the path already existing counts as success
    try expectSuccess(linux.makePath(dir, "a/b"));
    try tmp.dir.symLink(std.testing.io, "a/b/c", "link", .{});
    var buf: [16]u8 = undefined;
    switch (linux.readlink(dir, "link", &buf)) {
        .target => |target| try std.testing.expectEqualStrings("a/b/c", target),
        .errno => |e| std.debug.panic("readlink errno {d}", .{e}),
    }
    try std.testing.expectEqual(
        linux.ReadlinkResult{ .errno = .INVAL },
        linux.readlink(dir, "a", &buf),
    );
}

test "unix addresses that don't fit" {
    const longest: [linux.UnixAddress.max_path_len]u8 = @splat('x');
    try std.testing.expect(linux.UnixAddress.init(&longest) != null);
    const too_long: [linux.UnixAddress.max_path_len + 1]u8 = @splat('x');
    try std.testing.expect(linux.UnixAddress.init(&too_long) == null);
}

fn testBoundPort(fd: std.os.linux.fd_t) u16 {
    var addr: std.os.linux.sockaddr.in6 = undefined;
    var len: std.os.linux.socklen_t = @sizeOf(@TypeOf(addr));
    const rc = std.os.linux.getsockname(fd, @ptrCast(&addr), &len);
    std.debug.assert(std.os.linux.errno(rc) == .SUCCESS);
    // sockaddr.in and sockaddr.in6 both put the port after the family
    return std.mem.bigToNative(u16, addr.port);
}

test "a unix stream connection" {
    var addr: linux.UnixAddress = .{ .addr = .{ .path = undefined }, .path_len = undefined };
    // an abstract address, so the test leaves no socket file behind
    addr.path_len = (try std.fmt.bufPrint(
        &addr.addr.path,
        "\x00linux-zig-test-{d}",
        .{std.os.linux.getpid()},
    )).len;
    const listener = testFd(linux.socket(.unix_stream, .{}));
    defer linux.close(.socket, listener);
    try expectSuccess(linux.bind(.unix, listener, &addr));
    try expectSuccess(linux.listen(listener, 1));
    const client = testFd(linux.socket(.unix_stream, .{}));
    defer linux.close(.socket, client);
    try expectSuccess(linux.connect(.unix, client, &addr));
    const accepted = testFd(linux.accept(listener, .{}));
    defer linux.close(.socket, accepted);
    try expectSuccess(linux.shutdown(client, .both));
}

test "an inet stream connection over loopback" {
    const listener = testFd(linux.socket(.inet_stream, .{}));
    defer linux.close(.socket, listener);
    var addr: std.os.linux.sockaddr.in = .{
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    try expectSuccess(linux.bind(.inet, listener, &addr));
    try expectSuccess(linux.listen(listener, 1));
    addr.port = std.mem.nativeToBig(u16, testBoundPort(listener));

    const taken = testFd(linux.socket(.inet_stream, .{}));
    defer linux.close(.socket, taken);
    try std.testing.expectEqual(std.os.linux.E.ADDRINUSE, linux.bind(.inet, taken, &addr));

    const client = testFd(linux.socket(.inet_stream, .{}));
    defer linux.close(.socket, client);
    try std.testing.expectEqual(std.os.linux.E.NOTCONN, linux.shutdown(client, .both));
    try expectSuccess(linux.connect(.inet, client, &addr));
    const accepted = testFd(linux.accept(listener, .{}));
    defer linux.close(.socket, accepted);
    try expectSuccess(linux.shutdown(client, .both));
}

test "an inet6 stream connection over loopback" {
    const listener = switch (linux.socket(.inet6_stream, .{})) {
        .fd => |fd| fd,
        // IPv6 is disabled
        .errno => |e| if (e == .AFNOSUPPORT) return error.SkipZigTest else std.debug.panic(
            "socket errno {d}",
            .{e},
        ),
    };
    defer linux.close(.socket, listener);
    var addr: std.os.linux.sockaddr.in6 = .{
        .port = 0,
        .flowinfo = 0,
        .addr = @splat(0),
        .scope_id = 0,
    };
    addr.addr[15] = 1;
    switch (linux.bind(.inet6, listener, &addr)) {
        .SUCCESS => {},
        // ::1 isn't configured, as in some containers
        .ADDRNOTAVAIL => return error.SkipZigTest,
        else => |e| std.debug.panic("bind errno {d}", .{e}),
    }
    try expectSuccess(linux.listen(listener, 1));
    addr.port = std.mem.nativeToBig(u16, testBoundPort(listener));
    const client = testFd(linux.socket(.inet6_stream, .{}));
    defer linux.close(.socket, client);
    try expectSuccess(linux.connect(.inet6, client, &addr));
    const accepted = testFd(linux.accept(listener, .{}));
    defer linux.close(.socket, accepted);
}

test "fork returns the child's pid to the parent" {
    const pipe = testFds(linux.pipe2(.{}));
    defer linux.close(.pipe, pipe[0]);
    const pid = switch (linux.fork()) {
        .child => {
            const child_pid = std.os.linux.getpid();
            const failed = linux.writeAll(pipe[1], std.mem.asBytes(&child_pid)) != null;
            std.os.linux.exit_group(@intFromBool(failed));
        },
        .parent => |pid| pid,
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    };
    linux.close(.pipe, pipe[1]);
    var child_pid: std.os.linux.pid_t = undefined;
    try std.testing.expectEqual(
        linux.ReadAllResult.full,
        linux.readAll(pipe[0], std.mem.asBytes(&child_pid)),
    );
    try std.testing.expectEqual(child_pid, pid);
    try std.testing.expectEqual(@as(u32, 0), try testWait(pid));
}

test "fork returns EAGAIN at RLIMIT_NPROC" {
    // the limit doesn't apply to root
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    switch (linux.fork()) {
        .child => {
            var limit: std.os.linux.rlimit = undefined;
            if (std.os.linux.errno(std.os.linux.prlimit(0, .NPROC, null, &limit)) != .SUCCESS) {
                std.os.linux.exit_group(1);
            }
            limit.cur = 0;
            if (std.os.linux.errno(std.os.linux.prlimit(0, .NPROC, &limit, null)) != .SUCCESS) {
                std.os.linux.exit_group(2);
            }
            std.os.linux.exit_group(switch (linux.fork()) {
                .errno => |e| if (e == .AGAIN) 0 else 3,
                .child => 0,
                .parent => 4,
            });
        },
        .parent => |pid| try std.testing.expectEqual(@as(u32, 0), try testWait(pid)),
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    }
}

test "kill a child" {
    const pid = switch (linux.fork()) {
        .child => while (true) linux.nanosleep(std.time.ns_per_s),
        .parent => |pid| pid,
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    };
    try expectSuccess(linux.kill(pid, .TERM));
    const status = switch (linux.waitpid(.block, pid)) {
        .status => |status| status,
        .errno => |e| std.debug.panic("waitpid errno {d}", .{e}),
    };
    try std.testing.expect(std.os.linux.W.IFSIGNALED(status));
    try std.testing.expectEqual(std.os.linux.SIG.TERM, std.os.linux.W.TERMSIG(status));
    // the child is reaped, so it no longer exists
    try std.testing.expectEqual(std.os.linux.E.SRCH, linux.kill(pid, .TERM));
}

test "signal a thread" {
    // SIGURG is ignored by default
    try expectSuccess(linux.tkill(std.os.linux.gettid(), .URG));
    var tid: std.os.linux.pid_t = undefined;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(out: *std.os.linux.pid_t) void {
            out.* = std.os.linux.gettid();
        }
    }.run, .{&tid});
    thread.join();
    try std.testing.expectEqual(std.os.linux.E.SRCH, linux.tkill(tid, .URG));
}

test "start a new session in a child" {
    switch (linux.fork()) {
        .child => {
            if (linux.setsid() != .SUCCESS) std.os.linux.exit_group(1);
            const pid = std.os.linux.getpid();
            const sid = std.os.linux.syscall1(.getsid, 0);
            std.os.linux.exit_group(if (sid == pid) 0 else 2);
        },
        .parent => |pid| try std.testing.expectEqual(@as(u32, 0), try testWait(pid)),
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    }
}

test "a lowered RLIMIT_NOFILE fails calls on fds already open" {
    const pipe = testFds(linux.pipe2(.{}));
    defer for (pipe) |fd| linux.close(.pipe, fd);
    switch (linux.fork()) {
        .child => {
            var limit: std.os.linux.rlimit = undefined;
            if (std.os.linux.errno(std.os.linux.prlimit(0, .NOFILE, null, &limit)) != .SUCCESS) {
                std.os.linux.exit_group(1);
            }
            limit.cur = 1;
            if (std.os.linux.errno(std.os.linux.prlimit(0, .NOFILE, &limit, null)) != .SUCCESS) {
                std.os.linux.exit_group(1);
            }
            var fds = [_]std.os.linux.pollfd{
                .{ .fd = pipe[0], .events = std.os.linux.POLL.IN, .revents = 0 },
                .{ .fd = pipe[1], .events = std.os.linux.POLL.OUT, .revents = 0 },
            };
            switch (linux.poll(&fds, 0)) {
                .errno => |e| if (e != .INVAL) std.os.linux.exit_group(2),
                .ready => std.os.linux.exit_group(3),
            }
            std.os.linux.exit_group(if (linux.dup2(pipe[0], pipe[1]) == .BADF) 0 else 4);
        },
        .parent => |pid| try std.testing.expectEqual(@as(u32, 0), try testWait(pid)),
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    }
}

test "a process group leader can't start a session" {
    switch (linux.fork()) {
        .child => {
            // what a job-control shell does to the children it forks
            if (std.os.linux.errno(std.os.linux.setpgid(0, 0)) != .SUCCESS) {
                std.os.linux.exit_group(1);
            }
            std.os.linux.exit_group(if (linux.setsid() == .PERM) 0 else 2);
        },
        .parent => |pid| try std.testing.expectEqual(@as(u32, 0), try testWait(pid)),
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    }
}

test "open a file of 2 GiB or more" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fd = testFd(linux.open(
        .fromFd(tmp.dir.handle),
        "big",
        .{ .ACCMODE = .WRONLY, .CREAT = true },
        0o600,
    ));
    try expectSuccess(linux.ftruncate(fd, 3 << 30));
    linux.close(.ignore_flush_error, fd);
    // a 32-bit process gets EOVERFLOW without O_LARGEFILE
    const read_fd = testFd(linux.open(.fromFd(tmp.dir.handle), "big", .{ .ACCMODE = .RDONLY }, 0));
    linux.close(.ignore_flush_error, read_fd);
}

test "make an fd non-blocking" {
    const pipe = testFds(linux.pipe2(.{}));
    defer for (pipe) |fd| linux.close(.pipe, fd);
    var flags = switch (linux.getfl(pipe[0])) {
        .flags => |flags| flags,
        .errno => |e| std.debug.panic("getfl errno {d}", .{e}),
    };
    try std.testing.expect(!flags.NONBLOCK);
    flags.NONBLOCK = true;
    try expectSuccess(linux.setfl(pipe[0], flags));
    try std.testing.expectEqual(linux.GetflResult{ .flags = flags }, linux.getfl(pipe[0]));
    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(
        linux.ReadAllResult{ .fail = .{ .read = 0, .errno = .AGAIN } },
        linux.readAll(pipe[0], &buf),
    );
}

test "lock a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir: linux.DirFd = .fromFd(tmp.dir.handle);
    const first = testFd(linux.open(dir, "lock", .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644));
    defer linux.close(.ignore_flush_error, first);
    const second = testFd(
        linux.open(dir, "lock", .{ .ACCMODE = .RDWR }, 0),
    );
    defer linux.close(.ignore_flush_error, second);
    try expectSuccess(linux.flock(first, std.posix.LOCK.EX));
    try std.testing.expectEqual(
        std.os.linux.E.AGAIN,
        linux.flock(second, std.posix.LOCK.EX | std.posix.LOCK.NB),
    );
    try expectSuccess(linux.flock(first, std.posix.LOCK.UN));
    try expectSuccess(linux.flock(second, std.posix.LOCK.EX | std.posix.LOCK.NB));
}

test "size, map and read a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "hello world" });
    const fd = testFd(linux.open(.fromFd(tmp.dir.handle), "file", .{ .ACCMODE = .RDONLY }, 0));
    defer linux.close(.ignore_flush_error, fd);
    try std.testing.expectEqual(linux.FileSizeResult{ .size = 11 }, linux.fileSize(fd));
    switch (linux.mmap(.private_read, fd, 11)) {
        .mapped => |mapped| {
            defer linux.munmap(mapped);
            try std.testing.expectEqualStrings("hello world", mapped);
        },
        .errno => |e| std.debug.panic("mmap errno {d}", .{e}),
    }
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(linux.ReadAllResult.full, linux.preadAll(fd, buf[0..5], 6));
    try std.testing.expectEqualStrings("world", buf[0..5]);
    // the file ends before buf is full
    try std.testing.expectEqual(linux.ReadAllResult{ .eof = 5 }, linux.preadAll(fd, &buf, 6));
    try std.testing.expectEqual(linux.ReadAllResult.full, linux.readAll(fd, &buf));
    try std.testing.expectEqualStrings("hello wo", &buf);
}

test "unlink files and directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir: linux.DirFd = .fromFd(tmp.dir.handle);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "" });
    try tmp.dir.createDir(std.testing.io, "subdir", .default_dir);
    try expectSuccess(linux.unlink(dir, "file", 0));
    // a file that doesn't exist counts as unlinked
    try expectSuccess(linux.unlink(dir, "file", 0));
    try std.testing.expectEqual(std.os.linux.E.ISDIR, linux.unlink(dir, "subdir", 0));
    try expectSuccess(linux.unlink(dir, "subdir", std.os.linux.AT.REMOVEDIR));
}

test "fill a buffer with random bytes" {
    var buf: [32]u8 = @splat(0);
    try expectSuccess(linux.getrandom(&buf));
    try std.testing.expect(!std.mem.allEqual(u8, &buf, 0));
}

test "sleep and read the clocks" {
    const start: linux.MonoInstant(.MONOTONIC) = .now();
    linux.nanosleep(10 * std.time.ns_per_ms);
    const end: linux.MonoInstant(.MONOTONIC) = .now();
    try std.testing.expect(start.elapsedNs(end) >= 10 * std.time.ns_per_ms);
    try std.testing.expectEqual(std.math.Order.lt, start.order(end));
    const past_end = start.addNs(start.elapsedNs(end) + 1);
    try std.testing.expectEqual(std.math.Order.gt, past_end.order(end));
    try std.testing.expect(linux.clockGettime(.REALTIME).nanoseconds > 0);
}

test "name a thread" {
    const thread = try std.Thread.spawn(.{}, struct {
        fn run() !void {
            try expectSuccess(linux.setThreadName("linux-zig-test-thread"));
            const fd = testFd(
                linux.open(undefined, "/proc/thread-self/comm", .{ .ACCMODE = .RDONLY }, 0),
            );
            defer linux.close(.ignore_flush_error, fd);
            var buf: [32]u8 = undefined;
            // the kernel truncates the name to 15 bytes
            try std.testing.expectEqual(linux.ReadAllResult{ .eof = 16 }, linux.readAll(fd, &buf));
            try std.testing.expectEqualStrings("linux-zig-test-\n", buf[0..16]);
        }
    }.run, .{});
    thread.join();
}

test "a mutex serializes threads" {
    const Shared = struct {
        mutex: linux.Mutex = .{},
        count: u32 = 0,
        fn run(shared: *@This()) void {
            for (0..10_000) |_| {
                shared.mutex.lock();
                defer shared.mutex.unlock();
                shared.count += 1;
            }
        }
    };
    var shared: Shared = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Shared.run, .{&shared});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, 40_000), shared.count);
}

test "wait on an eventfd with epoll" {
    const epoll_fd = testFd(linux.epoll.create(.{}));
    defer linux.close(.epoll, epoll_fd);
    const event_fd = testFd(linux.eventfd.create(0, .nonblocking, .{}));
    defer linux.close(.eventfd, event_fd);
    try std.testing.expectEqual(
        linux.eventfd.TakeResult{ .errno = .AGAIN },
        linux.eventfd.take(event_fd),
    );
    try expectSuccess(linux.epoll.add(epoll_fd, event_fd, std.os.linux.EPOLL.IN, .{ .u64 = 7 }));
    var events: [2]std.os.linux.epoll_event = undefined;
    try std.testing.expectEqual(
        linux.PollResult{ .ready = 0 },
        linux.epoll.wait(epoll_fd, &events, 0),
    );
    try expectSuccess(linux.eventfd.add(event_fd, 3));
    try std.testing.expectEqual(
        linux.PollResult{ .ready = 1 },
        linux.epoll.wait(epoll_fd, &events, -1),
    );
    try std.testing.expectEqual(@as(u64, 7), events[0].data.u64);
    try std.testing.expectEqual(
        linux.eventfd.TakeResult{ .value = 3 },
        linux.eventfd.take(event_fd),
    );
    linux.epoll.del(epoll_fd, event_fd);
    try expectSuccess(linux.eventfd.add(event_fd, 1));
    try std.testing.expectEqual(
        linux.PollResult{ .ready = 0 },
        linux.epoll.wait(epoll_fd, &events, 0),
    );
}

test "write through an FdWriter" {
    const pipe = testFds(linux.pipe2(.{}));
    defer linux.close(.pipe, pipe[0]);
    var buffer: [16]u8 = undefined;
    var writer: linux.FdWriter = .init(pipe[1], &buffer);
    try writer.interface.print("{d}-{s}-", .{ 42, "abc" });
    try writer.interface.splatByteAll('x', 100);
    try writer.interface.flush();
    var buf: [128]u8 = undefined;
    try std.testing.expectEqual(linux.ReadAllResult.full, linux.readAll(pipe[0], buf[0..107]));
    try std.testing.expectEqualStrings("42-abc-", buf[0..7]);
    try std.testing.expect(std.mem.allEqual(u8, buf[7..107], 'x'));

    // with SIGPIPE ignored, a closed reader reports EPIPE
    const ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore, &old);
    defer std.posix.sigaction(std.posix.SIG.PIPE, &old, null);
    const closed_reader = testFds(linux.pipe2(.{}));
    linux.close(.pipe, closed_reader[0]);
    defer linux.close(.pipe, closed_reader[1]);
    var failing: linux.FdWriter = .init(closed_reader[1], &buffer);
    try failing.interface.writeAll("data");
    try std.testing.expectError(error.WriteFailed, failing.interface.flush());
    try std.testing.expectEqual(std.os.linux.E.PIPE, failing.errno);
}

test "iterate a directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b", .data = "" });
    try tmp.dir.createDir(std.testing.io, "c", .default_dir);
    const fd = testFd(
        linux.open(.fromFd(tmp.dir.handle), ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0),
    );
    defer linux.close(.ignore_flush_error, fd);
    var it: linux.DirIterator = .{ .fd = fd };
    var seen: [3]bool = @splat(false);
    while (true) switch (it.next()) {
        .entry => |entry| {
            const index = std.mem.indexOfScalar(u8, "abc", entry.name[0]).?;
            try std.testing.expectEqual(@as(usize, 1), entry.name.len);
            try std.testing.expect(!seen[index]);
            seen[index] = true;
            if (entry.type != std.os.linux.DT.UNKNOWN) try std.testing.expectEqual(
                @as(u8, if (index == 2) std.os.linux.DT.DIR else std.os.linux.DT.REG),
                entry.type,
            );
        },
        .end => break,
        .errno => |e| std.debug.panic("getdents64 errno {d}", .{e}),
    };
    try std.testing.expectEqual([3]bool{ true, true, true }, seen);
}

test "write many slices and splats through an FdWriter" {
    const fd = testMemfd(.{});
    defer linux.close(.memfd, fd);
    var buffer: [4]u8 = undefined;
    var writer: linux.FdWriter = .init(fd, &buffer);
    // more slices than one writev takes
    var slices: [10][]const u8 = undefined;
    for (&slices, 0..) |*slice, i| slice.* = "0123456789"[i..][0..1];
    try writer.interface.writeVecAll(&slices);
    // a multi-byte pattern, and a one-byte splat longer than one writev takes
    var pattern = [_][]const u8{"ab"};
    try writer.interface.writeSplatAll(&pattern, 300);
    try writer.interface.splatByteAll('y', 1000);
    try writer.interface.flush();

    var buf: [1611]u8 = undefined;
    try std.testing.expectEqual(linux.ReadAllResult{ .eof = 1610 }, linux.preadAll(fd, &buf, 0));
    try std.testing.expectEqualStrings("0123456789", buf[0..10]);
    for (0..300) |i| try std.testing.expectEqualStrings("ab", buf[10 + 2 * i ..][0..2]);
    try std.testing.expect(std.mem.allEqual(u8, buf[610..1610], 'y'));
}

test "read through an FdReader" {
    const pipe = testFds(linux.pipe2(.{}));
    defer linux.close(.pipe, pipe[0]);
    var data: [1000]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i);
    try std.testing.expectEqual(null, linux.writeAll(pipe[1], std.mem.asBytes(&@as(u32, 42))));
    try std.testing.expectEqual(null, linux.writeAll(pipe[1], &data));
    linux.close(.pipe, pipe[1]);

    var buffer: [8]u8 = undefined;
    var reader: linux.FdReader = .init(pipe[0], &buffer);
    try std.testing.expectEqual(42, try reader.interface.takeInt(u32, .little));
    // larger than the buffer, so readv fills it directly
    var got: [1000]u8 = undefined;
    try reader.interface.readSliceAll(&got);
    try std.testing.expectEqualSlices(u8, &data, &got);
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());

    // stream reads straight into a writer
    const pipe2 = testFds(linux.pipe2(.{}));
    defer linux.close(.pipe, pipe2[0]);
    try std.testing.expectEqual(null, linux.writeAll(pipe2[1], "streamed"));
    linux.close(.pipe, pipe2[1]);
    var streaming: linux.FdReader = .init(pipe2[0], &buffer);
    var out_buf: [16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expectEqual(8, try streaming.interface.streamRemaining(&out));
    try std.testing.expectEqualStrings("streamed", out.buffered());

    const o_path = testFd(linux.open(undefined, "/", .{ .ACCMODE = .RDONLY, .PATH = true }, 0));
    defer linux.close(.o_path, o_path);
    var failing: linux.FdReader = .init(o_path, &buffer);
    try std.testing.expectError(error.ReadFailed, failing.interface.takeByte());
    try std.testing.expectEqual(std.os.linux.E.BADF, failing.errno);
}

test "a seqpacket receive shorter than the message discards the rest" {
    const pair = testFds(linux.socketpair(.seqpacket, .{}));
    defer for (pair) |fd| linux.close(.socket, fd);
    const pipe = testFds(linux.pipe2(.{}));
    defer for (pipe) |fd| linux.close(.pipe, fd);
    try std.testing.expectEqual(
        linux.SizeResult{ .size = 7 },
        linux.sendWithFds(pair[0], "WITHFDS", &.{pipe[0]}, 0),
    );
    try std.testing.expectEqual(linux.SizeResult{ .size = 4 }, linux.send(pair[0], "next", 0));
    var buf: [2]u8 = undefined;
    var fds: [1]std.os.linux.fd_t = undefined;
    const received = switch (linux.recvWithFds(pair[1], &buf, &fds, 0)) {
        .received => |received| received,
        .errno => |e| std.debug.panic("recvWithFds errno {d}", .{e}),
    };
    linux.close(.pipe, fds[0]);
    try std.testing.expectEqual(@as(usize, 2), received.size);
    try std.testing.expectEqual(@as(usize, 1), received.fds_count);
    try std.testing.expect(received.data_truncated);
    // the rest of the message is gone; the next receive gets the next message
    var next: [8]u8 = undefined;
    try std.testing.expectEqual(linux.SizeResult{ .size = 4 }, linux.recv(pair[1], &next, 0));
    try std.testing.expectEqualStrings("next", next[0..4]);
}

test "FdReader takes 16 slices in one read" {
    const pipe = testFds(linux.pipe2(.{}));
    defer linux.close(.pipe, pipe[0]);
    try std.testing.expectEqual(null, linux.writeAll(pipe[1], "0123456789abcdefXYZ"));
    linux.close(.pipe, pipe[1]);
    var buffer: [8]u8 = undefined;
    var reader: linux.FdReader = .init(pipe[0], &buffer);
    var got: [16]u8 = undefined;
    var slices: [16][]u8 = undefined;
    for (&slices, 0..) |*slice, i| slice.* = got[i..][0..1];
    var size: usize = 0;
    while (size < got.len) size += try reader.interface.readVec(slices[size..]);
    try std.testing.expectEqualStrings("0123456789abcdef", &got);
    var rest: [3]u8 = undefined;
    try reader.interface.readSliceAll(&rest);
    try std.testing.expectEqualStrings("XYZ", &rest);
}

test "discard from an FdReader without a buffer" {
    const pipe = testFds(linux.pipe2(.{}));
    defer linux.close(.pipe, pipe[0]);
    try std.testing.expectEqual(null, linux.writeAll(pipe[1], "abcdef"));
    linux.close(.pipe, pipe[1]);
    var reader: linux.FdReader = .init(pipe[0], &.{});
    try reader.interface.discardAll(3);
    var rest: [3]u8 = undefined;
    try reader.interface.readSliceAll(&rest);
    try std.testing.expectEqualStrings("def", &rest);
    try std.testing.expectError(error.EndOfStream, reader.interface.discardAll(1));
}

test "an FdReader read with nowhere to put the data isn't the end" {
    const pipe = testFds(linux.pipe2(.{}));
    defer linux.close(.pipe, pipe[0]);
    try std.testing.expectEqual(null, linux.writeAll(pipe[1], "0123456789abcdefghij"));
    linux.close(.pipe, pipe[1]);
    var buffer: [8]u8 = undefined;
    var reader: linux.FdReader = .init(pipe[0], &buffer);
    _ = try reader.interface.peek(3);
    reader.interface.toss(1);
    var out_buf: [8]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expectEqual(0, try reader.interface.stream(&out, .limited(0)));
    try std.testing.expectEqual('1', try reader.interface.takeByte());
}

test "iterate a directory larger than one getdents64" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (0..300) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "file-{d:0>16}", .{i});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "" });
    }
    const fd = testFd(
        linux.open(.fromFd(tmp.dir.handle), ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0),
    );
    defer linux.close(.ignore_flush_error, fd);
    var it: linux.DirIterator = .{ .fd = fd };
    var seen: [300]bool = @splat(false);
    while (true) switch (it.next()) {
        .entry => |entry| {
            const index = try std.fmt.parseInt(usize, entry.name["file-".len..], 10);
            try std.testing.expect(!seen[index]);
            seen[index] = true;
        },
        .end => break,
        .errno => |e| std.debug.panic("getdents64 errno {d}", .{e}),
    };
    try std.testing.expect(std.mem.allEqual(bool, &seen, true));
}

test "make paths of every shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir: linux.DirFd = .fromFd(tmp.dir.handle);
    try expectSuccess(linux.makePath(dir, "trailing/slash/"));
    try testIsDir(dir, "trailing/slash");
    try expectSuccess(linux.makePath(dir, "double//slash"));
    try testIsDir(dir, "double/slash");
    try expectSuccess(linux.makePath(dir, "dot/../dotdot"));
    try testIsDir(dir, "dot");
    try testIsDir(dir, "dotdot");
    var abs_buf: [64]u8 = undefined;
    const abs = try std.fmt.bufPrint(&abs_buf, "/proc/self/fd/{d}/abs/path", .{tmp.dir.handle});
    try expectSuccess(linux.makePath(.cwd, abs));
    try testIsDir(dir, "abs/path");
    try std.testing.expectEqual(std.os.linux.E.NOENT, linux.makePath(dir, ""));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = "" });
    try std.testing.expectEqual(std.os.linux.E.NOTDIR, linux.makePath(dir, "file/sub"));
    // documented: a file at path counts as success
    try expectSuccess(linux.makePath(dir, "file"));
}

fn testIsDir(dir: linux.DirFd, path: [*:0]const u8) !void {
    const fd = testFd(linux.open(
        dir,
        path,
        .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .PATH = true },
        0,
    ));
    linux.close(.o_path, fd);
}

test "exec a path relative to a directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "prog",
        .data = "#!/bin/sh\nexit 3\n",
        .flags = .{ .permissions = .fromMode(0o755) },
    });
    const argv = [_:null]?[*:0]const u8{ "prog", null };
    const envp = [_:null]?[*:0]const u8{null};
    // a script needs a dir fd without close-on-exec
    const dir_fd = testFd(
        linux.open(
            .fromFd(tmp.dir.handle),
            ".",
            .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = false },
            0,
        ),
    );
    defer linux.close(.ignore_flush_error, dir_fd);
    const cases = [_]struct { fd: std.os.linux.fd_t, status: u32 }{
        .{ .fd = dir_fd, .status = 3 },
        .{ .fd = tmp.dir.handle, .status = 100 + @backingInt(std.os.linux.E.NOENT) },
    };
    for (cases) |case| {
        switch (linux.fork()) {
            .child => std.os.linux.exit_group(100 + @as(i32, @backingInt(linux.execve(
                .path,
                .{ .dir_fd = .fromFd(case.fd), .path = "prog" },
                &argv,
                &envp,
            )))),
            .parent => |pid| try std.testing.expectEqual(case.status, try testWait(pid)),
            .errno => |e| std.debug.panic("fork errno {d}", .{e}),
        }
    }
}

/// Sends this thread SIGALRM, handled without SA_RESTART, every 10ms until
/// stopped, so a blocking call returns EINTR. It repeats because a signal that
/// arrives before the call blocks interrupts nothing.
const TestInterrupter = struct {
    old: std.posix.Sigaction,
    done: std.atomic.Value(bool) = .init(false),
    thread: std.Thread,

    fn start(self: *TestInterrupter) !void {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = struct {
                fn handle(_: std.posix.SIG) callconv(.c) void {}
            }.handle },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.ALRM, &action, &self.old);
        self.done = .init(false);
        self.thread = try std.Thread.spawn(.{}, run, .{ self, std.os.linux.gettid() });
    }
    fn run(self: *TestInterrupter, tid: std.os.linux.pid_t) void {
        while (!self.done.load(.acquire)) {
            linux.nanosleep(10 * std.time.ns_per_ms);
            _ = linux.tkill(tid, .ALRM);
        }
    }
    fn stop(self: *TestInterrupter) void {
        self.done.store(true, .release);
        self.thread.join();
        std.posix.sigaction(std.posix.SIG.ALRM, &self.old, null);
    }
};

// Each of these blocks on another process, so a signal handler installed
// without SA_RESTART must be able to interrupt it (README, Rule: EINTR).
test "blocking calls return EINTR" {
    var interrupter: TestInterrupter = undefined;
    try interrupter.start();
    defer interrupter.stop();

    const pair = testFds(linux.socketpair(.stream, .{}));
    defer for (pair) |fd| linux.close(.socket, fd);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(linux.SizeResult{ .errno = .INTR }, linux.recv(pair[0], &buf, 0));
    try std.testing.expectEqual(linux.SizeResult{ .errno = .INTR }, linux.read(pair[0], &buf));

    const pipe = testFds(linux.pipe2(.{}));
    defer for (pipe) |fd| linux.close(.pipe, fd);
    try std.testing.expectEqual(
        linux.ReadAllResult{ .fail = .{ .read = 0, .errno = .INTR } },
        linux.readAll(pipe[0], &buf),
    );
    // a full pipe blocks the rest of the write, and the bytes already written
    // come back with the errno
    const page_size = std.heap.pageSize();
    try expectSuccess(
        std.os.linux.errno(std.os.linux.fcntl(pipe[1], std.os.linux.F.SETPIPE_SZ, page_size)),
    );
    var big: [64 * 1024]u8 = @splat('x');
    const incomplete = linux.writeAll(pipe[1], &big).?;
    try std.testing.expectEqual(std.os.linux.E.INTR, incomplete.errno);
    try std.testing.expect(incomplete.written > 0 and incomplete.written < big.len);

    var events: [1]std.os.linux.epoll_event = undefined;
    const epoll_fd = testFd(linux.epoll.create(.{}));
    defer linux.close(.epoll, epoll_fd);
    try std.testing.expectEqual(
        linux.PollResult{ .errno = .INTR },
        linux.epoll.wait(epoll_fd, &events, -1),
    );
    var poll_fds = [_]std.os.linux.pollfd{.{
        .fd = pair[0],
        .events = std.os.linux.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(linux.PollResult{ .errno = .INTR }, linux.poll(&poll_fds, -1));

    const blocking_eventfd = testFd(linux.eventfd.create(0, .{}, .{}));
    defer linux.close(.eventfd, blocking_eventfd);
    try std.testing.expectEqual(
        linux.eventfd.TakeResult{ .errno = .INTR },
        linux.eventfd.take(blocking_eventfd),
    );

    const listener = testFd(linux.socket(.unix_stream, .{}));
    defer linux.close(.socket, listener);
    var addr: linux.UnixAddress = .{ .addr = .{ .path = undefined }, .path_len = undefined };
    addr.path_len = (try std.fmt.bufPrint(
        &addr.addr.path,
        "\x00linux-zig-eintr-{d}",
        .{std.os.linux.getpid()},
    )).len;
    try expectSuccess(linux.bind(.unix, listener, &addr));
    try expectSuccess(linux.listen(listener, 1));
    try std.testing.expectEqual(
        linux.FdResult{ .errno = .INTR },
        linux.accept(listener, .{}),
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir: linux.DirFd = .fromFd(tmp.dir.handle);
    // opening a FIFO for reading waits for a writer
    try expectSuccess(
        std.os.linux.errno(std.os.linux.mknodat(
            tmp.dir.handle,
            "fifo",
            std.os.linux.S.IFIFO | 0o600,
            0,
        )),
    );
    try std.testing.expectEqual(
        linux.FdResult{ .errno = .INTR },
        linux.open(dir, "fifo", .{ .ACCMODE = .RDONLY }, 0),
    );
    // a blocking lock waits for the holder
    const holder = testFd(
        linux.open(dir, "lock", .{ .ACCMODE = .RDWR, .CREAT = true }, 0o644),
    );
    defer linux.close(.ignore_flush_error, holder);
    const waiter = testFd(
        linux.open(dir, "lock", .{ .ACCMODE = .RDWR }, 0),
    );
    defer linux.close(.ignore_flush_error, waiter);
    try expectSuccess(linux.flock(holder, std.posix.LOCK.EX));
    try std.testing.expectEqual(std.os.linux.E.INTR, linux.flock(waiter, std.posix.LOCK.EX));

    const pid = switch (linux.fork()) {
        .child => while (true) linux.nanosleep(std.time.ns_per_s),
        .parent => |pid| pid,
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    };
    try std.testing.expectEqual(linux.WaitpidResult{ .errno = .INTR }, linux.waitpid(.block, pid));
    try expectSuccess(linux.kill(pid, .KILL));
    _ = linux.waitpid(.block, pid);
}

// A peer can send an O_PATH fd, or any kind of fd, over a unix socket, and a
// parent can leave one open, so these errnos can reach a correct program and
// must not be misuse (README, Why EBADF isn't always misuse).
test "errnos an fd from outside the process can cause" {
    const o_path = testFd(
        linux.open(undefined, "/", .{ .ACCMODE = .RDONLY, .PATH = true }, 0),
    );
    defer linux.close(.o_path, o_path);
    const epoll_fd = testFd(linux.epoll.create(.{}));
    defer linux.close(.epoll, epoll_fd);
    var buf: [1]u8 = undefined;
    var fds: [1]std.os.linux.fd_t = undefined;
    const inet_addr: std.os.linux.sockaddr.in = .{
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    try std.testing.expectEqual(
        std.os.linux.E.BADF,
        linux.epoll.add(epoll_fd, o_path, std.os.linux.EPOLL.IN, .{ .u64 = 0 }),
    );
    try std.testing.expectEqual(linux.SizeResult{ .errno = .BADF }, linux.recv(o_path, &buf, 0));
    try std.testing.expectEqual(linux.SizeResult{ .errno = .BADF }, linux.send(o_path, "x", 0));
    try std.testing.expectEqual(
        linux.SizeResult{ .errno = .BADF },
        linux.sendWithFds(o_path, "x", &.{o_path}, 0),
    );
    try std.testing.expectEqual(
        linux.RecvWithFdsResult{ .errno = .BADF },
        linux.recvWithFds(o_path, &buf, &fds, 0),
    );
    try std.testing.expectEqual(
        linux.FdResult{ .errno = .BADF },
        linux.accept(o_path, .{}),
    );
    try std.testing.expectEqual(std.os.linux.E.BADF, linux.listen(o_path, 1));
    try std.testing.expectEqual(std.os.linux.E.BADF, linux.shutdown(o_path, .both));
    try std.testing.expectEqual(std.os.linux.E.BADF, linux.bind(.inet, o_path, &inet_addr));

    // a pipe isn't a socket
    const pipe = testFds(linux.pipe2(.{}));
    defer for (pipe) |fd| linux.close(.pipe, fd);
    try std.testing.expectEqual(
        linux.SizeResult{ .errno = .NOTSOCK },
        linux.recv(pipe[0], &buf, 0),
    );
    try std.testing.expectEqual(linux.SizeResult{ .errno = .NOTSOCK }, linux.send(pipe[1], "x", 0));
    try std.testing.expectEqual(
        linux.FdResult{ .errno = .NOTSOCK },
        linux.accept(pipe[0], .{}),
    );
    try std.testing.expectEqual(std.os.linux.E.NOTSOCK, linux.listen(pipe[0], 1));
    try std.testing.expectEqual(std.os.linux.E.NOTSOCK, linux.shutdown(pipe[0], .both));
    try std.testing.expectEqual(std.os.linux.E.NOTSOCK, linux.bind(.inet, pipe[0], &inet_addr));

    // a regular file can't be polled
    const memfd = testMemfd(.{});
    defer linux.close(.memfd, memfd);
    try std.testing.expectEqual(
        std.os.linux.E.PERM,
        linux.epoll.add(epoll_fd, memfd, std.os.linux.EPOLL.IN, .{ .u64 = 0 }),
    );

    // a datagram socket can't listen or accept
    const dgram = testFd(linux.socket(.unix_dgram, .{}));
    defer linux.close(.socket, dgram);
    try std.testing.expectEqual(std.os.linux.E.OPNOTSUPP, linux.listen(dgram, 1));
    try std.testing.expectEqual(
        linux.FdResult{ .errno = .OPNOTSUPP },
        linux.accept(dgram, .{}),
    );

    // an unbound unix socket can't listen, and a bound one can't bind again
    const unbound = testFd(linux.socket(.unix_stream, .{}));
    defer linux.close(.socket, unbound);
    try std.testing.expectEqual(std.os.linux.E.INVAL, linux.listen(unbound, 1));
    const bound = testFd(linux.socket(.inet_stream, .{}));
    defer linux.close(.socket, bound);
    const unbound_inet = testFd(linux.socket(.inet_stream, .{}));
    defer linux.close(.socket, unbound_inet);
    try expectSuccess(linux.bind(.inet, bound, &inet_addr));
    try std.testing.expectEqual(std.os.linux.E.INVAL, linux.bind(.inet, bound, &inet_addr));

    // an inet6 address on an inet socket
    const inet6_addr: std.os.linux.sockaddr.in6 = .{
        .port = 0,
        .flowinfo = 0,
        .addr = @splat(0),
        .scope_id = 0,
    };
    try std.testing.expectEqual(
        std.os.linux.E.AFNOSUPPORT,
        linux.bind(.inet6, unbound_inet, &inet6_addr),
    );
}

test "epoll.add errnos correct use can cause" {
    // a file's registration outlives closing one fd while a dup of it stays
    // open, so adding the reused fd number finds it already in the set
    const epoll_fd = testFd(linux.epoll.create(.{}));
    defer linux.close(.epoll, epoll_fd);
    const original = testFd(linux.eventfd.create(0, .{}, .{}));
    const kept = testFd(linux.dup(original, .{}));
    defer linux.close(.eventfd, kept);
    try expectSuccess(linux.epoll.add(epoll_fd, original, std.os.linux.EPOLL.IN, .{ .u64 = 0 }));
    linux.close(.eventfd, original);
    const reused = testFd(linux.dup(kept, .{}));
    defer linux.close(.eventfd, reused);
    try std.testing.expectEqual(original, reused);
    try std.testing.expectEqual(
        std.os.linux.E.EXIST,
        linux.epoll.add(epoll_fd, reused, std.os.linux.EPOLL.IN, .{ .u64 = 0 }),
    );

    // a file in too many nested epoll sets (reverse_path_check in
    // fs/eventpoll.c allows 500 paths of depth 2)
    const event_fd = testFd(linux.eventfd.create(0, .{}, .{}));
    defer linux.close(.eventfd, event_fd);
    const outer = testFd(linux.epoll.create(.{}));
    defer linux.close(.epoll, outer);
    var inner: [501]std.os.linux.fd_t = undefined;
    var inner_count: usize = 0;
    defer for (inner[0..inner_count]) |fd| linux.close(.epoll, fd);
    const last = for (&inner, 0..) |*slot, i| {
        slot.* = testFd(linux.epoll.create(.{}));
        inner_count += 1;
        try expectSuccess(linux.epoll.add(outer, slot.*, std.os.linux.EPOLL.IN, .{ .u64 = 0 }));
        const errno = linux.epoll.add(slot.*, event_fd, std.os.linux.EPOLL.IN, .{ .u64 = 0 });
        if (errno != .SUCCESS) break .{ i, errno };
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 500), last[0]);
    try std.testing.expectEqual(std.os.linux.E.INVAL, last[1]);

    // an epoll fd from elsewhere that already watches this one makes a loop
    const other = testFd(linux.epoll.create(.{}));
    defer linux.close(.epoll, other);
    try expectSuccess(linux.epoll.add(other, epoll_fd, std.os.linux.EPOLL.IN, .{ .u64 = 0 }));
    try std.testing.expectEqual(
        std.os.linux.E.LOOP,
        linux.epoll.add(epoll_fd, other, std.os.linux.EPOLL.IN, .{ .u64 = 0 }),
    );
}

test "read and write what's available" {
    const pipe = testFds(linux.pipe2(.nonblocking));
    defer linux.close(.pipe, pipe[0]);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(linux.SizeResult{ .errno = .AGAIN }, linux.read(pipe[0], &buf));
    try std.testing.expectEqual(linux.SizeResult{ .size = 2 }, linux.write(pipe[1], "$ "));
    // returns the 2 bytes there are, rather than waiting to fill buf
    try std.testing.expectEqual(linux.SizeResult{ .size = 2 }, linux.read(pipe[0], &buf));
    try std.testing.expectEqualStrings("$ ", buf[0..2]);
    // a full pipe takes what fits
    try expectSuccess(std.os.linux.errno(std.os.linux.fcntl(
        pipe[1],
        std.os.linux.F.SETPIPE_SZ,
        std.heap.pageSize(),
    )));
    var big: [64 * 1024]u8 = @splat('x');
    const written = switch (linux.write(pipe[1], &big)) {
        .size => |size| size,
        .errno => |e| std.debug.panic("write errno {d}", .{e}),
    };
    try std.testing.expect(written > 0 and written < big.len);
    try std.testing.expectEqual(linux.SizeResult{ .errno = .AGAIN }, linux.write(pipe[1], &big));
    linux.close(.pipe, pipe[1]);
    while (true) switch (linux.read(pipe[0], &buf)) {
        .size => |size| if (size == 0) break,
        .errno => |e| std.debug.panic("read errno {d}", .{e}),
    };
}

test "check whether a child has exited" {
    const pid = switch (linux.fork()) {
        .child => while (true) linux.nanosleep(std.time.ns_per_s),
        .parent => |pid| pid,
        .errno => |e| std.debug.panic("fork errno {d}", .{e}),
    };
    try std.testing.expectEqual(linux.WaitpidNohangResult.running, linux.waitpid(.nohang, pid));
    try expectSuccess(linux.kill(pid, .KILL));
    const status = while (true) switch (linux.waitpid(.nohang, pid)) {
        .status => |status| break status,
        .running => linux.nanosleep(std.time.ns_per_ms),
        .errno => |e| std.debug.panic("waitpid errno {d}", .{e}),
    };
    try std.testing.expect(std.os.linux.W.IFSIGNALED(status));
    try std.testing.expectEqual(std.os.linux.SIG.KILL, std.os.linux.W.TERMSIG(status));
}

const std = @import("std");
const linux = @import("linux");
