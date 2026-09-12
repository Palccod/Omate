#!/usr/bin/env python3
"""Secure atomic state saver for Omate.

Usage: secure-save.py <dir> <name> <content>

Replaces Quickshell FileView atomic writes, which create and publish
files through <dir> resolved by path and never check what the ancestors
along that path are. This helper instead:

1. walks every component of <dir> from the root, opening each with
   O_NOFOLLOW|O_DIRECTORY and requiring it to be owned by the current
   user or by root (creating missing components with 0700 along the
   way, and refusing non-sticky group/other-writable root-owned ones),
2. requires the last component of <dir> (the publish directory) to be
   owned by the current user and not group/other-writable,
3. stages the payload in a 0600 temp file created O_EXCL|O_NOFOLLOW
   relative to the final directory descriptor,
4. publishes with renameat against that descriptor, so a swapped or
   symlinked ancestor after the checks cannot redirect the write,
5. revalidates before publishing that the descriptor still matches the
   directory as reachable by path, and re-checks ownership on both the
   descriptor and the published file.

Any failure exits non-zero and leaves any existing state file untouched.
The payload arrives as a single argv element, which is safe because the
caller bounds state files to 64 KiB (kernel per-arg limit is 128 KiB).
"""

import os
import secrets
import sys


def die(message: str):
    print(f"omate-secure-save: {message}", file=sys.stderr)
    sys.exit(1)


def check_component(fd: int, label: str, final: bool):
    """Ancestor policy: every component must be owned by the current user
    or by root, and a component owned by someone else (root) must not be
    group/other-writable unless it is sticky, since the swap attack needs
    rename rights inside it. The directory we publish into (final) must
    be owned by the current user and writable by no one else."""
    st = os.fstat(fd)
    mine = st.st_uid == os.geteuid()
    if not mine and st.st_uid != 0:
        die(f"{label} is owned by uid {st.st_uid}, not the user or root")
    if not mine and st.st_mode & 0o022 and not st.st_mode & 0o1000:
        die(f"{label} is group/other writable and not sticky")
    if final:
        if not mine:
            die(f"{label} is not owned by the current user")
        if st.st_mode & 0o022:
            die(f"{label} is group/other writable")
    return st


def open_dir_no_follow(fd: int, name: str, label: str, final: bool) -> int:
    """Open <name> below the open directory <fd> with O_NOFOLLOW,
    creating it with 0700 first when missing. <label> is the full path
    of the component being opened, for error messages."""
    try:
        sub = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                      dir_fd=fd)
    except FileNotFoundError:
        try:
            os.mkdir(name, 0o700, dir_fd=fd)
        except OSError as error:
            die(f"cannot create {label}: {error.strerror}")
        try:
            sub = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                          dir_fd=fd)
        except OSError as error:
            die(f"cannot open {label} without following links: "
                f"{error.strerror}")
    except OSError as error:
        die(f"cannot open {label} without following links: "
            f"{error.strerror}")
    check_component(sub, label, final=final)
    return sub


def resolve_dir(path: str) -> int:
    """Open <path> as a directory descriptor, checking every ancestor
    on the way. Missing components are created, owned by us, 0700."""
    if not os.path.isabs(path):
        die("directory must be an absolute path")
    components = [c for c in path.split("/") if c]
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    check_component(fd, "/", final=False)
    walked = ""
    for index, component in enumerate(components):
        walked += "/" + component
        fd = open_dir_no_follow(fd, component, walked or "/",
                                final=index == len(components) - 1)
    return fd


def dirfd_matches_path(fd: int, path: str) -> bool:
    """Revalidate: the descriptor must still be the directory reachable
    by path, i.e. nothing renamed or replaced it since we opened it."""
    try:
        by_path = os.stat(path)
    except OSError:
        return False
    by_fd = os.fstat(fd)
    return (by_path.st_dev, by_path.st_ino) == (by_fd.st_dev, by_fd.st_ino)


def main():
    if len(sys.argv) != 4:
        die("usage: secure-save.py <dir> <name> <content>")
    directory, name, content = sys.argv[1], sys.argv[2], sys.argv[3]

    if "/" in name or name in (".", "..") or not name:
        die("name must be a single path component")

    # Two attempts: the first can lose a race with something swapping the
    # directory; revalidation catches that and a fresh walk re-checks all
    # ancestors.
    for _ in range(2):
        dirfd = resolve_dir(directory)

        if not dirfd_matches_path(dirfd, directory):
            os.close(dirfd)
            continue

        temp = f".{name}.{secrets.token_hex(6)}.tmp"
        try:
            tmpfd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                            | os.O_NOFOLLOW, 0o600, dir_fd=dirfd)
            with os.fdopen(tmpfd, "w") as handle:
                handle.write(content)
                handle.flush()
                os.fsync(handle.fileno())
            if not dirfd_matches_path(dirfd, directory):
                raise OSError("directory swapped during staging")
            # renameat against the descriptor: even if a later ancestor was
            # swapped after staging, the publish lands in the checked
            # directory, not wherever the path now points.
            os.rename(temp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
            os.fsync(dirfd)
            published = os.open(name, os.O_RDONLY | os.O_NOFOLLOW,
                                dir_fd=dirfd)
            check_component(published, f"{directory}/{name}", final=False)
            os.close(published)
            os.close(dirfd)
            return
        except OSError as error:
            try:
                os.unlink(temp, dir_fd=dirfd)
            except OSError:
                pass
            if not dirfd_matches_path(dirfd, directory):
                os.close(dirfd)
                continue
            die(f"cannot publish {directory}/{name}: {error.strerror}")

    die(f"{directory} kept changing under us; giving up")


if __name__ == "__main__":
    main()
