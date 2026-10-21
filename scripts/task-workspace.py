#!/usr/bin/env python3
"""Small lifecycle manager for explicitly registered task workspaces."""
import argparse
import filecmp
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / "output"
WORK = BASE / "task-workspaces"
DELIVER = BASE / "task-deliveries"
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
def now():
    return datetime.now(timezone.utc).isoformat()
def safe_id(value):
    if not ID.fullmatch(value) or value in (".", ".."):
        raise ValueError("task ID must use 1-64 letters, digits, dot, underscore, or hyphen")
    return value
def safe_dir(path, create=False):
    if path.is_symlink():
        raise ValueError(f"refusing symlink: {path}")
    if create:
        path.mkdir(parents=True, exist_ok=True)
    if not path.is_dir():
        raise ValueError(f"directory missing: {path}")
    return path
def paths(task):
    task = safe_id(task)
    safe_dir(BASE, True)
    safe_dir(WORK, True)
    safe_dir(DELIVER, True)
    return WORK / task, DELIVER / task
def manifest(work):
    file = work / "manifest.json"
    if file.is_symlink() or not file.is_file():
        raise ValueError(f"registered manifest missing or unsafe: {file}")
    return file
def read(work):
    if work.is_symlink() or work.parent != WORK:
        raise ValueError("workspace path is unsafe")
    data = json.loads(manifest(work).read_text())
    if data.get("task_id") != work.name or not ID.fullmatch(work.name):
        raise ValueError("manifest does not match registered workspace")
    return data
def write(work, data):
    file = manifest(work)
    temp = work / ".manifest.tmp"
    if temp.is_symlink():
        raise ValueError(f"refusing symlink manifest temp: {temp}")
    temp.write_text(json.dumps(data, indent=2) + "\n")
    temp.replace(file)
def retained_by_live_or_unknown(data):
    if data.get("dependencies") != []:
        return True
    pid = data.get("pid")
    if pid is None:
        return False
    if type(pid) is not int or pid <= 0:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except (PermissionError, OSError):
        return True
def create(task, retention=24):
    if retention < 0:
        raise ValueError("failure retention cannot be negative")
    work, _ = paths(task)
    if work.exists() or work.is_symlink():
        raise ValueError(f"task workspace already exists: {work}")
    work.mkdir()
    data = {"task_id": task, "status": "created", "pid": None,
            "created_at": now(), "updated_at": now(),
            "failure_retention_hours": retention, "delivered_at": None,
            "dependencies": []}
    (work / "manifest.json").write_text(json.dumps(data, indent=2) + "\n")
    return work
def run_task(task, argv, retention=24):
    work = create(task, retention)
    data = read(work)
    env = os.environ.copy()
    env["OPEN_ISLAND_TASK_WORKSPACE"] = str(work)
    try:
        process = subprocess.Popen(argv, cwd=ROOT, env=env)
        data.update(status="running", pid=process.pid, updated_at=now())
        write(work, data)
        code = process.wait()
        data.update(status="succeeded" if code == 0 else "failed",
                    pid=None, updated_at=now(), exit_code=code)
        write(work, data)
        return code
    except Exception:
        active = "process" in locals() and process.poll() is None
        data.update(status="running" if active else "failed",
                    pid=process.pid if active else None, updated_at=now())
        write(work, data)
        raise
def artifact_path(work, relative):
    rel = Path(relative)
    if rel.is_absolute() or not rel.parts or ".." in rel.parts:
        raise ValueError(f"artifact must be a relative path inside workspace: {relative}")
    candidate = work / rel
    cursor = work
    for part in rel.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise ValueError(f"refusing symlink artifact: {cursor}")
    resolved = candidate.resolve(strict=True)
    if not resolved.is_relative_to(work.resolve()):
        raise ValueError(f"artifact escapes workspace: {relative}")
    if candidate.is_dir():
        for entry in candidate.rglob("*"):
            if entry.is_symlink():
                raise ValueError(f"refusing symlink inside artifact: {entry}")
    return candidate
def equal_tree(left, right):
    if left.is_dir():
        if not right.is_dir(): return False
        a, b = sorted(p.name for p in left.iterdir()), sorted(p.name for p in right.iterdir())
        return a == b and all(equal_tree(left / name, right / name) for name in a)
    return right.is_file() and filecmp.cmp(left, right, shallow=False)
def complete(task, verify, artifacts, delivery_root=None):
    work, dest = paths(task)
    data = read(work)
    if data.get("status") != "succeeded":
        raise ValueError("complete requires a succeeded task")
    if retained_by_live_or_unknown(data):
        raise ValueError("complete refuses a live process or unknown/non-empty dependencies")
    if not verify or not artifacts:
        raise ValueError("complete requires --verify-json and at least one --artifact")
    command = json.loads(verify)
    if not isinstance(command, list) or not command or not all(isinstance(x, str) for x in command):
        raise ValueError("--verify-json must be a non-empty JSON argv array")
    result = subprocess.run(command, cwd=ROOT, check=False)
    if result.returncode:
        raise ValueError(f"verification failed with exit code {result.returncode}")
    root = Path(delivery_root).expanduser() if delivery_root else DELIVER
    if not root.is_absolute():
        root = ROOT / root
    unresolved = root
    while unresolved != ROOT and unresolved != unresolved.parent:
        if unresolved.is_symlink():
            raise ValueError(f"refusing symlink delivery path: {unresolved}")
        unresolved = unresolved.parent
    root = root.resolve()
    if not root.is_relative_to(ROOT.resolve()):
        raise ValueError("delivery directory must be inside repository")
    safe_dir(root, True)
    dest = root / safe_id(task)
    if dest.exists() or dest.is_symlink():
        raise ValueError(f"delivery already exists: {dest}")
    staged = root / ("." + safe_id(task) + ".staging")
    if staged.exists() or staged.is_symlink():
        raise ValueError(f"staging path already exists: {staged}")
    staged.mkdir()
    try:
        for item in artifacts:
            src = artifact_path(work, item)
            target = staged / item
            target.parent.mkdir(parents=True, exist_ok=True)
            if src.is_dir():
                shutil.copytree(src, target, symlinks=False)
            elif src.is_file():
                shutil.copy2(src, target)
            else:
                raise ValueError(f"artifact is not a regular file or directory: {item}")
        for item in artifacts:
            copied = staged / item
            if copied.is_symlink() or not copied.exists():
                raise ValueError(f"artifact copy missing or unsafe: {item}")
            source = work / item
            if not equal_tree(source, copied):
                raise ValueError(f"artifact file copy differs: {item}")
        staged.rename(dest)
    except Exception:
        shutil.rmtree(staged, ignore_errors=True)
        raise
    data.update(status="delivered", delivered_at=now(), updated_at=now(), pid=None)
    write(work, data)
    shutil.rmtree(work)
    print(dest)
def cleanup(task=None):
    safe_dir(WORK, True)
    candidates = [WORK / safe_id(task)] if task else list(WORK.iterdir())
    for work in candidates:
        if work.is_symlink() or not work.is_dir():
            print(f"preserved unknown entry: {work}")
            continue
        try:
            data = read(work)
            status = data.get("status")
            if retained_by_live_or_unknown(data):
                print(f"preserved live process or unknown/non-empty dependencies: {work}")
            elif status == "delivered":
                shutil.rmtree(work)
            elif status == "failed":
                deadline = datetime.fromisoformat(data["updated_at"]) + timedelta(hours=float(data["failure_retention_hours"]))
                if datetime.now(timezone.utc) >= deadline:
                    shutil.rmtree(work)
                else:
                    print(f"preserved until retention expires: {work}")
            else:
                print(f"preserved status {status!r}: {work}")
        except Exception as exc:
            print(f"preserved unknown/unsafe entry {work}: {exc}")
def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("create"); p.add_argument("--task", required=True); p.add_argument("--failure-retention-hours", type=float, default=24)
    p = sub.add_parser("run"); p.add_argument("--task", required=True); p.add_argument("--failure-retention-hours", type=float, default=24); p.add_argument("argv", nargs=argparse.REMAINDER)
    p = sub.add_parser("complete"); p.add_argument("--task", required=True); p.add_argument("--verify-json", required=True); p.add_argument("--artifact", action="append", required=True); p.add_argument("--delivery-dir")
    p = sub.add_parser("cleanup"); p.add_argument("--task")
    args = parser.parse_args()
    try:
        if args.action == "create": print(create(args.task, args.failure_retention_hours))
        elif args.action == "run":
            argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
            if not argv: raise ValueError("run requires -- followed by a command")
            return run_task(args.task, argv, args.failure_retention_hours)
        elif args.action == "complete": complete(args.task, args.verify_json, args.artifact, args.delivery_dir)
        else: cleanup(args.task)
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0
if __name__ == "__main__":
    sys.exit(main())
