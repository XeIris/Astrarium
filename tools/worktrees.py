#!/usr/bin/env python3
"""Every worktree of this clone at a glance, and any of them run without the editor.

    tools/worktrees.py                     list them: branch, last commit, changes, models, last check run
    tools/worktrees.py play NAME [ARG...]  ready NAME and start the game from it (ARGs go to the game)
    tools/worktrees.py edit NAME           ready NAME and open it in the Godot editor
    tools/worktrees.py ready NAME|--all    only ready them
    tools/worktrees.py pick                list, then ask which one to play (tools/worktrees.command)

NAME is a row number, a branch, a folder name or any unique part of one. Ready means
the gitignored authored models (assets/craft, pads, sites) that the main checkout
has are cloned in (never over a file already there; --source picks another
checkout), and the import cache is brought up to date headless. On APFS the models are copy-on-write clones: no disk.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
MODELS = ("assets/craft", "assets/pads", "assets/sites")
IMPORT_TIMEOUT = 600


def git(*args, cwd=ROOT, check=True):
    # No optional locks: a status refresh would rewrite the index and reorder the list.
    done = subprocess.run(["git", "--no-optional-locks", *args], cwd=cwd, capture_output=True, text=True, timeout=60)
    if check and done.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def worktrees():
    """[{path, branch, head}] in `git worktree list` order (the main checkout first)."""
    found, entry = [], {}
    for line in git("worktree", "list", "--porcelain").splitlines() + [""]:
        if not line:
            if entry.get("path") and Path(entry["path"]).is_dir():
                found.append(entry)
            entry = {}
        elif line.startswith("worktree "):
            entry["path"] = line[len("worktree "):]
        elif line.startswith("HEAD "):
            entry["head"] = line[5:]
        elif line.startswith("branch "):
            entry["branch"] = line[len("branch refs/heads/"):]
    return found


def models(path):
    """The gitignored authored models present under `path`, relative."""
    present = set()
    for folder in MODELS:
        for model in (Path(path) / folder).glob("*.glb"):
            present.add(str(model.relative_to(path)))
    return present


def runs_folder():
    return Path(git("rev-parse", "--path-format=absolute", "--git-common-dir").strip()) / "astrarium-check"


def last_runs():
    """{worktree root: newest check.py run state}: each worktree's last finished run
    (last.json), or a run in progress."""
    folder = runs_folder()
    try:
        newest = json.loads((folder / "last.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        newest = {}
    for path in folder.glob("*.json") if folder.is_dir() else []:
        if path.name in ("times.json", "passes.json", "last.json"):
            continue
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
            root = state["root"]
            if root not in newest or state["updated"] > newest[root].get("updated", 0):
                newest[root] = state
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return newest


def ago(seconds):
    seconds = max(int(seconds), 0)
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if seconds >= size:
            return f"{seconds // size}{unit}"
    return f"{seconds}s"


def describe(entry, runs, source_models):
    path = entry["path"]
    stamp, subject = (git("log", "-1", "--format=%ct%x09%s", cwd=path, check=False).strip().split("\t", 1) + [""])[:2]
    index = Path(path) / git("rev-parse", "--git-path", "index", cwd=path, check=False).strip()
    touched = max(int(stamp) if stamp.isdigit() else 0, int(index.stat().st_mtime) if index.is_file() else 0)
    changed = len([line for line in git("status", "--porcelain", cwd=path, check=False).splitlines() if line])
    run = runs.get(path)
    result = ""
    if run:
        state = run.get("finished") or "running"
        failed = run.get("failed") or []
        result = f"{state}{' ' + ','.join(failed[:2]) if failed else ''} {ago(time.time() - run['updated'])} ago"
    return {"path": path, "name": entry.get("branch") or f"({Path(path).name}, detached)",
            "commit_age": ago(time.time() - int(stamp)) if stamp.isdigit() else "?", "subject": subject, "touched": touched,
            "changed": changed, "models": len(models(path) & source_models), "extra": len(models(path) - source_models),
            "wanted": len(source_models),
            "imported": (Path(path) / ".godot/imported").is_dir(), "last_check": result}


def table(rows):
    home, width = str(Path.home()), shutil.get_terminal_size().columns if sys.stdout.isatty() else 1000
    name = max([len(row["name"]) for row in rows] + [8])
    print(f" #  {'worktree':<{name}}  commit  tree        models  last check run")
    for index, row in enumerate(rows, 1):
        tree = f"{row['changed']} changed" if row["changed"] else "clean"
        have = f"{row['models']}/{row['wanted']}" + (f"+{row['extra']}" if row["extra"] else "") + ("" if row["imported"] else " !imp")
        print(f"{index:>2}  {row['name']:<{name}}  {row['commit_age']:>6}  {tree:<10}  {have:<6}  {row['last_check']}"[:width])
        print(f"    {row['path'].replace(home, '~')}: {row['subject']}"[:width])
    print("models: the main checkout's authored models present here (+ others of its own); `ready` clones the rest. "
          "!imp: never imported")


def choose(rows, name):
    if name.isdigit() and 1 <= int(name) <= len(rows):
        return rows[int(name) - 1]
    exact = [row for row in rows if name in (row["name"], Path(row["path"]).name, row["path"])]
    partial = [row for row in rows if name.lower() in row["name"].lower() or name.lower() in row["path"].lower()]
    matches = exact or partial
    if len(matches) == 1:
        return matches[0]
    names = ", ".join(row["name"] for row in matches) if matches else "none; run with no arguments to list them"
    sys.exit(f"worktrees: {name!r} matches {names}")


def godot():
    for candidate in (os.environ.get("GODOT"), shutil.which("godot"), shutil.which("Godot"),
                      "/Applications/Godot.app/Contents/MacOS/Godot"):
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    sys.exit("worktrees: Godot not found; set GODOT")


def clone(source, target):
    """Copy-on-write where the filesystem has it (APFS, Btrfs), else a plain copy."""
    target.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin" and subprocess.run(["cp", "-c", str(source), str(target)], capture_output=True).returncode == 0:
        return
    shutil.copy2(source, target)


def ready(row, source):
    """Clone in missing models from `source`, then import headless."""
    path = Path(row["path"])
    missing = sorted(models(source) - models(path))
    for relative in missing:
        clone(Path(source) / relative, path / relative)
    if missing:
        print(f"cloned {len(missing)} model(s) from {source}: {', '.join(Path(m).stem for m in missing)}")
    base = git("rev-parse", "HEAD", cwd=source).strip()
    if missing and subprocess.run(["git", "diff", "--quiet", base, "HEAD", "--", "model_sources"], cwd=path).returncode == 1:
        print("note: this branch changes model_sources/; the cloned models are the source checkout's, so rebuild "
              "them (model_sources/blender) to see this branch's")
    started = time.monotonic()
    command = [godot(), "--headless", "--path", str(path), "--import", "--quit"]
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=IMPORT_TIMEOUT, start_new_session=True)
    except subprocess.TimeoutExpired:
        sys.exit(f"worktrees: import of {path} did not finish in {IMPORT_TIMEOUT}s")
    errors = [line for line in (done.stdout + done.stderr).splitlines() if "ERROR" in line]
    print(f"imported {path.name} in {time.monotonic() - started:.1f}s" + (f" ({len(errors)} error lines; first: {errors[0][:160]})" if errors else ""))
    if done.returncode != 0:
        sys.exit(f"worktrees: import exited {done.returncode}")


def launch(row, extra, editor):
    path = Path(row["path"])
    log = runs_folder() / f"{'edit' if editor else 'play'}-{path.name}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    command = [godot(), *(["-e"] if editor else []), "--path", str(path), *extra]
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=path, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
    print(f"{'editor' if editor else 'game'} started from {row['name']} (pid {process.pid}); log {log}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", nargs="?", default="list", choices=("list", "play", "edit", "ready", "pick"))
    parser.add_argument("name", nargs="?")
    parser.add_argument("args", nargs=argparse.REMAINDER, help="play: arguments for the game, e.g. mode=flight craft=falcon9")
    parser.add_argument("--all", action="store_true", help="ready: every worktree")
    parser.add_argument("--json", action="store_true", help="list: as JSON")
    parser.add_argument("--source", help="the checkout to clone models from (default: the one with the most)")
    options = parser.parse_args()
    entries = worktrees()
    source = options.source or entries[0]["path"]
    source_models = models(source)
    runs = last_runs()
    rows = [describe(entry, runs, source_models) for entry in entries]
    # The main checkout first, then the most recently touched (committed, staged or checked out).
    rows = rows[:1] + sorted(rows[1:], key=lambda row: -row["touched"])
    if options.action == "list":
        if options.json:
            print(json.dumps(rows, indent=1))
        else:
            table(rows)
        return 0
    if options.action == "pick":
        table(rows)
        answer = input("\nnumber or name to play (e then a number to edit, Enter to quit): ").strip()
        if not answer:
            return 0
        editor = answer.startswith("e ")
        row = choose(rows, answer[2:].strip() if editor else answer)
        ready(row, source)
        launch(row, [], editor)
        return 0
    if options.action == "ready" and options.all:
        for row in rows:
            ready(row, source)
        return 0
    if not options.name:
        parser.error(f"{options.action} needs a worktree NAME (a row number from the list)")
    row = choose(rows, options.name)
    ready(row, source)
    if options.action in ("play", "edit"):
        launch(row, options.args, options.action == "edit")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"worktrees: {error}")
    except KeyboardInterrupt:
        sys.exit(130)
