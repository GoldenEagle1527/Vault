#!/usr/bin/env python3
import json
import os
import signal
import socket
import subprocess
import sys
import time

VAULT = "/root/.vault"
SOCK = VAULT + "/site-supervisor.sock"
PIDFILE = VAULT + "/site-supervisor.pid"
STATE = VAULT + "/site-supervisor.state.json"
EVENTS = VAULT + "/site-supervisor.events.jsonl"
READY_DEFAULT = 15.0
POLL = 0.4

sites = {}
stop_flag = False


def ensure_dir():
    os.makedirs(VAULT, exist_ok=True)


def now():
    return int(time.time())


def emit(site_id, state, **extra):
    rec = {"v": 1, "id": site_id, "state": state, "ts": now()}
    rec.update(extra)
    line = json.dumps(rec, ensure_ascii=False) + "\n"
    with open(EVENTS, "a") as f:
        f.write(line)
        f.flush()


def write_state():
    payload = {
        "sites": {
            sid: {
                "state": s["state"],
                "pid": s.get("pid"),
                "port": s.get("port"),
                "processAlive": alive(s.get("pid")),
                "listening": s["state"] == "listening",
            }
            for sid, s in sites.items()
        }
    }
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(payload, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE)


def alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return os.path.isdir("/proc/%d" % int(pid))
    except (OSError, ValueError):
        return False


def children_of(pid):
    kids = []
    try:
        names = os.listdir("/proc")
    except OSError:
        return kids
    want = str(int(pid))
    for name in names:
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/status" % name) as f:
                for line in f:
                    if line.startswith("PPid:"):
                        if line.split()[1] == want:
                            kids.append(int(name))
                        break
        except (OSError, IndexError, ValueError):
            continue
    return kids


def listen_inodes(port):
    if not port:
        return []
    hexport = "%04X" % int(port)
    found = []
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(path) as f:
                next(f)
                for line in f:
                    parts = line.split()
                    if len(parts) < 10:
                        continue
                    local = parts[1]
                    st = parts[3].upper()
                    inode = parts[9]
                    _addr, _, p = local.rpartition(":")
                    if p.upper() == hexport and st == "0A" and inode != "0":
                        found.append(inode)
        except (OSError, StopIteration):
            continue
    return found


def pid_owns_inodes(pid, inodes):
    if not pid or not inodes:
        return False
    wanted = set(inodes)
    pids = [int(pid)] + children_of(pid)
    for p in pids:
        fd_dir = "/proc/%d/fd" % p
        try:
            names = os.listdir(fd_dir)
        except OSError:
            continue
        for name in names:
            try:
                target = os.readlink(os.path.join(fd_dir, name))
            except OSError:
                continue
            if target.startswith("socket:[") and target[8:-1] in wanted:
                return True
    return False


def port_owned_by(pid, port):
    return pid_owns_inodes(pid, listen_inodes(port))


def anyone_listening(port):
    return bool(listen_inodes(port))


def kill_tree(pid):
    if not pid or not alive(pid):
        return
    pids = children_of(pid) + [int(pid)]
    for p in pids:
        if p <= 1:
            continue
        try:
            os.kill(p, signal.SIGTERM)
        except OSError:
            pass
    time.sleep(0.35)
    for p in pids:
        if p <= 1:
            continue
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass


def start_site(req):
    sid = req.get("id") or ""
    cwd = req.get("cwd") or ""
    cmd = req.get("cmd") or ""
    port = req.get("port")
    log_path = req.get("log") or ""
    pid_file = req.get("pid_file") or ""
    timeout = float(req.get("timeout") or READY_DEFAULT)
    if not sid or not cwd or not cmd:
        return {"ok": False, "error": "id/cwd/cmd 不能为空"}
    existing = sites.get(sid)
    if existing and existing.get("state") == "listening" and alive(existing.get("pid")):
        if port_owned_by(existing.get("pid"), existing.get("port") or port):
            return {
                "ok": True,
                "state": "listening",
                "id": sid,
                "pid": existing.get("pid"),
                "already": True,
                "listening": True,
                "processAlive": True,
            }
    if port and anyone_listening(port):
        owner = existing.get("pid") if existing else None
        if not owner or not port_owned_by(owner, port):
            return {
                "ok": False,
                "state": "occupied",
                "id": sid,
                "error": "端口已被其他进程占用，无法启动",
            }
    if existing and alive(existing.get("pid")):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if port_owned_by(existing.get("pid"), port):
                existing["state"] = "listening"
                write_state()
                emit(sid, "listening", pid=existing.get("pid"))
                return {
                    "ok": True,
                    "state": "listening",
                    "id": sid,
                    "pid": existing.get("pid"),
                    "already": True,
                    "listening": True,
                    "processAlive": True,
                }
            if not alive(existing.get("pid")):
                break
            time.sleep(POLL)
        return {
            "ok": False,
            "state": "start_failed",
            "id": sid,
            "error": "启动超时：端口尚未监听",
        }
    os.makedirs(cwd, exist_ok=True)
    logf = None
    if log_path:
        log_dir = os.path.dirname(log_path)
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)
        logf = open(log_path, "ab", buffering=0)
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=cwd,
            shell=True,
            executable="/bin/sh",
            stdout=logf,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except Exception as e:
        if logf:
            logf.close()
        return {"ok": False, "state": "start_failed", "id": sid, "error": str(e)}
    pid = proc.pid
    if pid_file:
        try:
            with open(pid_file, "w") as f:
                f.write("%d\n" % pid)
        except OSError:
            pass
    sites[sid] = {
        "state": "starting",
        "pid": pid,
        "port": port,
        "proc": proc,
        "log": log_path,
        "pid_file": pid_file,
    }
    write_state()
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            sites[sid]["state"] = "exited"
            write_state()
            emit(sid, "exited", pid=pid, code=proc.returncode)
            if logf:
                logf.close()
            return {
                "ok": False,
                "state": "start_failed",
                "id": sid,
                "error": "进程已退出",
                "pid": pid,
            }
        if port_owned_by(pid, port):
            sites[sid]["state"] = "listening"
            write_state()
            emit(sid, "listening", pid=pid)
            return {
                "ok": True,
                "state": "listening",
                "id": sid,
                "pid": pid,
                "already": False,
                "listening": True,
                "processAlive": True,
            }
        time.sleep(POLL)
    kill_tree(pid)
    sites[sid]["state"] = "exited"
    write_state()
    emit(sid, "start_failed", pid=pid)
    if logf:
        logf.close()
    return {
        "ok": False,
        "state": "start_failed",
        "id": sid,
        "error": "启动超时：端口尚未监听",
        "pid": pid,
    }


def stop_site(req):
    sid = req.get("id") or ""
    rec = sites.get(sid)
    if rec is None:
        return {"ok": True, "state": "exited", "id": sid, "already": True}
    pid = rec.get("pid")
    proc = rec.get("proc")
    kill_tree(pid)
    if proc is not None:
        try:
            proc.wait(timeout=2)
        except Exception:
            pass
    pid_file = rec.get("pid_file")
    if pid_file:
        try:
            os.remove(pid_file)
        except OSError:
            pass
    rec["state"] = "exited"
    write_state()
    emit(sid, "exited", pid=pid)
    return {"ok": True, "state": "exited", "id": sid, "already": False}


def status_site(req):
    sid = req.get("id")
    if sid:
        rec = sites.get(sid)
        if rec is None:
            return {
                "ok": True,
                "known": False,
                "id": sid,
                "listening": False,
                "processAlive": False,
                "state": "unknown",
            }
        listening = rec.get("state") == "listening" and port_owned_by(
            rec.get("pid"), rec.get("port")
        )
        return {
            "ok": True,
            "known": True,
            "id": sid,
            "state": rec.get("state"),
            "pid": rec.get("pid"),
            "listening": listening,
            "processAlive": alive(rec.get("pid")),
        }
    return {
        "ok": True,
        "sites": {
            k: {
                "state": v.get("state"),
                "pid": v.get("pid"),
                "listening": v.get("state") == "listening",
                "processAlive": alive(v.get("pid")),
            }
            for k, v in sites.items()
        },
    }


def shutdown_all():
    for sid in list(sites.keys()):
        stop_site({"id": sid})


def handle(req):
    op = (req.get("op") or "").strip()
    if op == "ping":
        return {"ok": True, "state": "pong"}
    if op == "start":
        return start_site(req)
    if op == "stop":
        return stop_site(req)
    if op == "status":
        return status_site(req)
    if op == "shutdown":
        shutdown_all()
        global stop_flag
        stop_flag = True
        return {"ok": True, "state": "shutdown"}
    return {"ok": False, "error": "未知 op"}


def monitor_once():
    for sid, rec in list(sites.items()):
        if rec.get("state") != "listening":
            continue
        pid = rec.get("pid")
        proc = rec.get("proc")
        dead = (proc is not None and proc.poll() is not None) or not alive(pid)
        if dead:
            rec["state"] = "exited"
            write_state()
            emit(sid, "exited", pid=pid)
            continue
        if rec.get("port") and not port_owned_by(pid, rec.get("port")):
            emit(sid, "port_lost", pid=pid)
            kill_tree(pid)
            rec["state"] = "exited"
            write_state()
            emit(sid, "exited", pid=pid, reason="port_lost")


def serve():
    ensure_dir()
    open(EVENTS, "a").close()
    with open(PIDFILE, "w") as f:
        f.write("%d\n" % os.getpid())
    write_state()
    try:
        os.unlink(SOCK)
    except OSError:
        pass
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(SOCK)
    sock.listen(8)
    sock.settimeout(0.4)
    signal.signal(signal.SIGTERM, lambda *_: shutdown_and_exit(sock))
    signal.signal(signal.SIGINT, lambda *_: shutdown_and_exit(sock))
    while not stop_flag:
        try:
            conn, _ = sock.accept()
        except socket.timeout:
            monitor_once()
            continue
        except OSError:
            break
        try:
            data = b""
            while not data.endswith(b"\n"):
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            req = json.loads(data.decode("utf-8") or "{}")
            reply = handle(req)
            conn.sendall((json.dumps(reply, ensure_ascii=False) + "\n").encode("utf-8"))
        except Exception as e:
            try:
                conn.sendall(
                    (json.dumps({"ok": False, "error": str(e)}) + "\n").encode("utf-8")
                )
            except OSError:
                pass
        finally:
            try:
                conn.close()
            except OSError:
                pass
        monitor_once()
    try:
        sock.close()
        os.unlink(SOCK)
    except OSError:
        pass


def shutdown_and_exit(sock):
    global stop_flag
    stop_flag = True
    shutdown_all()
    try:
        sock.close()
    except OSError:
        pass
    sys.exit(0)


def rpc(raw):
    req = json.loads(raw)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    last = None
    for _ in range(50):
        try:
            sock.connect(SOCK)
            last = None
            break
        except OSError as e:
            last = e
            time.sleep(0.1)
    if last is not None:
        sys.stdout.write(json.dumps({"ok": False, "error": "看守未就绪：%s" % last}) + "\n")
        return 1
    sock.sendall((json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8"))
    data = b""
    while not data.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    sock.close()
    sys.stdout.write(data.decode("utf-8") if data else '{"ok":false,"error":"空响应"}\n')
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "serve":
        serve()
        return 0
    if len(argv) >= 3 and argv[1] == "rpc":
        return rpc(argv[2])
    sys.stderr.write("usage: site_supervisor.py serve | rpc '<json>'\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
