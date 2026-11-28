# linux-zig

linux-zig provides typed Zig wrappers around Linux syscalls, and helpers built
on them that make the correct thing convenient, such as `FileSync` for saving a
file so its contents reach storage.

## API rules

Every wrapper follows these rules. Check new and changed wrappers against them.

### Rule: Errno

If a syscall fails, return the errno as `std.os.linux.E`. Use a union with an
`errno` field when it also returns a value.

Include docs that name each errno a caller might act on, such as `EAGAIN` or
`EADDRINUSE`.

#### Why not use Zig errors?

Zig errors are useful when the caller wants an exhaustive list of every error,
so each one can go to a specific code path. But when a filesystem or driver
chooses the errno, a call can return hundreds of different values: a FUSE server
can reply to `close`, `fsync` or `read` with any errno up to 511. An exhaustive
list is impractical. In practice, almost every errno takes the same code path,
and an application can opt in to handling the few that take another.

### Rule: Unexpected errnos

When a call that doesn't return an errno gets one anyway, and it isn't misuse,
pass it to `panicUnexpectedErrno`, which panics in every build mode.

#### Why panic in release builds?

The errno means the caller misused the call in a way linux-zig didn't
anticipate, or linux-zig is wrong and correct use can make it fail. The second
can happen in a correct program, so treating the errno as unreachable would make
correct use undefined behavior.

### Rule: Release

Releasing a resource can't fail, so don't report a release as failing. An errno
from a release is either misuse or a report about something else, such as
`close` reporting a flush error after releasing the fd.

#### Why can't a release fail?

There's nothing to recover: the resource is gone either way. `close` releases
the fd even when it returns an errno, so retrying it would close whatever fd
reused the number.

### Rule: Misuse

Pass an errno to `apiMisuse` only if it means the caller broke the function's
contract, and document that contract. Never do it for an errno a filesystem or
driver chooses. Check each case against the kernel source.

#### Why only errnos that correct use can't produce?

`apiMisuse` panics in safe builds and is unreachable in release builds, and
catching misuse doesn't justify crashing or invoking undefined behavior on
correct use. A filesystem or driver can return almost any errno: a FUSE server
can reply to a request with any errno up to 511. "Why EBADF isn't always misuse"
below walks through a real case.

### Rule: Narrowing

Take a comptime kind as the first parameter, only if it removes a code path or
picks the type of an argument or of the result. If the kind describes an fd,
give it a `fromFdKind` and a declaration for each `FdKind`, so a caller can name
what the fd is.

For example, a file without a flush operation can't fail to close, so
`close(.flush_unreachable, fd)` returns nothing, and `close(.pipe, fd)` says the
same thing by naming the fd. `bind` and `connect` take a domain that picks the
address type.

#### Why only then, and why first?

Narrowing that only changes which errnos are possible doesn't change what the
caller does, and every kind is more API to learn. A kind that picks an
argument's type has to come first, because a parameter's type can only depend on
the parameters before it, so every kind comes first for consistency.

### Rule: Variations

Zig has a choice between using suffixes for function variations, such as `send`
and `sendWithFds`, and using a comptime parameter, such as
`waitpid(.nohang, pid)`. Use a comptime parameter if a caller could pick the
wrong variation without knowing another exists, such as `close(.pipe, fd)` or
`execve(.fd, memfd, argv, envp)`. Otherwise use suffixes: a caller who needs to
send fds can't do it by accident with `send`.

#### Why a comptime parameter then?

Typing `waitpid(.` lists every variation. A caller who doesn't know about a
variation uses another one, and the mistake can go unnoticed. They might handle
results that can't happen, such as a flush error from closing a pipe. Or the
call works in testing and fails later: a blocking `waitpid` after `SIGTERM`
hangs forever on a child that ignores it.

#### Why suffixes otherwise?

Separate functions keep each signature simple: `send` doesn't take an fds
argument it never uses.

### Rule: Paths

If a call takes a path, take a `DirFd` before it, as the `*at` syscalls do. A
caller passes `.cwd`, `.fromFd(dir)`, or `undefined` for a literal absolute
path.

#### Why a DirFd?

One function then covers both forms of the syscall, such as open(2) and
openat(2), and `.cwd` names what `AT_FDCWD` means. `undefined` is safe for a
literal absolute path because the kernel never reads the dir fd. A path built at
runtime could turn out to be relative, so it gets `.cwd`.

### Rule: EINTR

Retry `EINTR` in calls that finish on their own, such as filesystem operations.
Return it from calls that can block indefinitely on another process: reads and
writes on a pipe, socket or tty, a FIFO open, a blocking lock, or waiting for a
child.

#### Why not always retry?

A blocking call gets `EINTR` when the application installed a signal handler
without `SA_RESTART`, or set a socket timeout (`SO_RCVTIMEO`, `SO_SNDTIMEO`).
Retrying would defeat either one. The handler couldn't interrupt the call, and
the timeout would start over. Some calls, such as `epoll_wait` and `poll`, also
return `EINTR` when the process is stopped and continued, even with no handler.
A call that finishes on its own has nothing to interrupt.

### Rule: Printing errnos

Print an errno as `errno {d}`.

#### Why not `{t}`?

`std.os.linux.E` is non-exhaustive, and `{t}` panics on an errno that has no
name.

## Why EBADF isn't always misuse

Catching misuse doesn't justify crashing or invoking undefined behavior on
correct use. The NFS client returns `EBADF` on a valid fd once it loses the
file's open state. That happens when a server reboot or an expired lease can't
be recovered (`nfs_page_create` in `fs/nfs/pagelist.c`). Every operation that
uses that state can then fail with it: reads, writes, truncating, locking, and
the `fsync` or `close` that reports a failed write back.

FUSE goes further. A FUSE server can reply to any request with `EBADF`, and the
kernel passes it through (`fuse_dev_do_write` in `fs/fuse/dev.c`). So any call
that reaches a filesystem can fail with it, such as `statx`, `getdents64`,
`mmap`, or an `openat`, `mkdirat`, `unlinkat` or `readlinkat` relative to a
directory fd.

An fd that came from outside the process can cause it too. A peer can send an
`O_PATH` fd over a unix socket, or a parent can leave one open, and most
syscalls reject an `O_PATH` fd with `EBADF`: reads, writes, `mmap`, epoll and
every socket call (`fdget` in `fs/file.c`).

Treating `EBADF` as misuse in any of these would crash a correct program in safe
builds, and make it undefined behavior in release builds. Only `close` with a
kind that can't flush, `dup`, `dup2` with equal fds and `getfl`, which accept
any open fd, and `epoll.del`, whose fd must already be in the set, still treat
`EBADF` as misuse. `dup2` with different fds returns `EBADF`, because it can
also mean the new fd is at or above `RLIMIT_NOFILE`.

The cost is that in those operations, using an fd after closing it is no longer
caught where it happens. It returns the same errno, and the caller handles it
like any other failure. Nothing can tell the two apart. So we choose not
crashing correct programs, and leave closed-fd bugs to ownership discipline,
such as `FileSync` closing an fd exactly once.

std decides the other way. `std.Io.Threaded` passes `EBADF` to `errnoBug`, which
panics in Debug builds and returns `error.Unexpected` otherwise. So a Debug
build crashes when an NFS server reboots. std likely judges NFS losing a file's
state rare enough that catching use-after-close, the far more common cause of
`EBADF`, is worth that crash in Debug builds.
