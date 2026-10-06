import contextlib
import errno
import os
if os.name == "nt":
    import msvcrt
else:
    import fcntl
import os
import tempfile
import time


class BusyError(TimeoutError):
    pass


@contextlib.contextmanager
def ops_lock(path=None, timeout=15, poll=0.05):
    lock_path = path or os.environ.get("VPN_OPS_LOCK", "/run/vpn/ops.lock")
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    deadline = time.monotonic() + timeout
    try:
        if os.name == "nt" and os.fstat(fd).st_size == 0:
            os.write(fd, b"\0")
            os.lseek(fd, 0, os.SEEK_SET)
        while True:
            try:
                if os.name == "nt":
                    os.lseek(fd, 0, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                else:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as exc:
                if os.name != "nt" and exc.errno not in (errno.EACCES, errno.EAGAIN):
                    raise
                if time.monotonic() >= deadline:
                    raise BusyError("operation lock is busy") from exc
                time.sleep(poll)
        yield
    finally:
        os.close(fd)


def atomic_write(path, data, *, mode=None):
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    old_stat = None
    try:
        old_stat = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        pass
    fd, temp_path = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", dir=directory)
    try:
        payload = data.encode() if isinstance(data, str) else data
        with os.fdopen(fd, "wb") as stream:
            wanted_mode = mode if mode is not None else (old_stat.st_mode & 0o777 if old_stat else 0o644)
            if os.name == "posix":
                if old_stat:
                    os.fchown(stream.fileno(), old_stat.st_uid, old_stat.st_gid)
                os.fchmod(stream.fileno(), wanted_mode)
            else:
                os.chmod(temp_path, wanted_mode)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_path, path)
        if os.name == "posix":
            dirfd = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(dirfd)
            finally:
                os.close(dirfd)
    except Exception:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass
        raise
