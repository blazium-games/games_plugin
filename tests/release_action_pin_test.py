#!/usr/bin/env python3
"""The release job must not run a movable action ref before it publishes the addon zip.

`python3 tests/release_action_pin_test.py` fails while `.github/workflows/release.yml`
checks out `actions/checkout` or `Bioblaze/game-semver-action` by tag in the job that
packs `addons/blazium_games` and runs `gh release create`. It passes when every action
that job runs is a local `./` action or a full 40-hex commit SHA (a tag move then
resolves to a different commit than the one the workflow named), or when that job no
longer runs a third-party action before it publishes.

The harness follows the runner steps that turn `uses:` into a process: parse the ref,
resolve it when the job starts, download that commit's archive, run the JavaScript
entrypoint with the workspace as the working directory and the step inputs in the
environment, then run this workflow's own pack and publish scripts. The attacker
input is a force-moved tag whose action appends a marker to the player script and,
when the job token can write contents, posts a release to the stand-in API.
"""

from __future__ import annotations

import http.server
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import zipfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
CANARY = "BLZ_RELEASE_CANARY"
# Obvious placeholder. The workflow names this secret; the test never uses a real value.
JOB_TOKEN = "ghs_test_placeholder"
SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
EXPR_RE = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")


class WorkflowLoader(yaml.SafeLoader):
    pass


# PyYAML 6 treats the workflow key `on` as a boolean. Keep it as a string.
for _ch, _resolvers in list(WorkflowLoader.yaml_implicit_resolvers.items()):
    WorkflowLoader.yaml_implicit_resolvers[_ch] = [
        (tag, pattern)
        for tag, pattern in _resolvers
        if tag != "tag:yaml.org,2002:bool"
    ]


def load_workflow(text: str) -> dict:
    data = yaml.load(text, Loader=WorkflowLoader)
    if not isinstance(data, dict) or not isinstance(data.get("jobs"), dict):
        raise AssertionError("release workflow has no jobs map")
    return data


def parse_uses(uses: str):
    """Match ActionManifestManagerWrapper.ParseActionReference for owner/repo@ref."""
    if uses.startswith("docker://"):
        return ("docker", uses, None, None)
    if uses.startswith("./") or uses.startswith(".\\"):
        return ("local", uses, None, None)
    at = uses.rfind("@")
    ref = None
    repo = uses
    if at > 0:
        ref = uses[at + 1 :]
        repo = uses[:at]
    parts = repo.split("/")
    if len(parts) < 2 or not ref:
        raise AssertionError(f"unparsed action ref {uses!r}")
    name = f"{parts[0]}/{parts[1]}"
    path = "/".join(parts[2:]) if len(parts) > 2 else ""
    return ("github", name, ref, path)


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=check,
        text=True,
        capture_output=True,
    )


def write_action(repo: Path, script: str, token_default: str) -> None:
    (repo / "action.yml").write_text(
        textwrap.dedent(
            f"""\
            name: fixture
            description: fixture action
            inputs:
              personal_github_token:
                required: false
                default: ""
              token:
                required: false
                default: "{token_default}"
            runs:
              using: node20
              main: index.js
            """
        ),
        encoding="utf-8",
    )
    (repo / "index.js").write_text(script, encoding="utf-8")


BENIGN_JS = textwrap.dedent(
    """\
    const fs = require('fs');
    const out = process.env.GITHUB_OUTPUT;
    if (out) fs.appendFileSync(out, 'simple_version=1.2.3\\n');
    const marker = process.env.BENIGN_MARKER;
    if (marker) fs.appendFileSync(marker, (process.env.BENIGN_NAME || 'action') + '\\n');
    """
)

MALICIOUS_JS = textwrap.dedent(
    """\
    const fs = require('fs');
    const path = require('path');
    const http = require('http');
    const ws = process.env.GITHUB_WORKSPACE || process.cwd();
    const target = path.join(ws, 'addons', 'blazium_games', 'blazium_games.gd');
    fs.mkdirSync(path.dirname(target), {recursive: true});
    fs.appendFileSync(target, '\\n# BLZ_RELEASE_CANARY\\n');
    const out = process.env.GITHUB_OUTPUT;
    if (out) fs.appendFileSync(out, 'simple_version=1.2.3\\n');
    const token = process.env.INPUT_PERSONAL_GITHUB_TOKEN || process.env.INPUT_TOKEN || '';
    const api = process.env.BLZ_RELEASE_API || '';
    if (!token || !api) process.exit(0);
    const payload = JSON.stringify({
      tag_name: 'v1.2.3',
      name: 'blazium_games-1.2.3.zip',
      body: fs.readFileSync(target, 'utf8'),
    });
    const url = new URL(api + '/repos/blazium-games/games_plugin/releases');
    const req = http.request({
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + token,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
      },
    }, (res) => { res.resume(); });
    req.on('error', () => process.exit(1));
    req.write(payload);
    req.end();
    """
)


def init_action_repo(path: Path, tag: str) -> tuple[str, str]:
    path.mkdir(parents=True, exist_ok=True)
    git(path, "init", "-b", "master")
    git(path, "config", "user.email", "test@example.com")
    git(path, "config", "user.name", "Test")
    write_action(path, BENIGN_JS, "")
    git(path, "add", "action.yml", "index.js")
    git(path, "commit", "-m", "benign")
    benign = git(path, "rev-parse", "HEAD").stdout.strip()
    git(path, "tag", tag)
    write_action(path, MALICIOUS_JS, "${{ github.token }}")
    git(path, "add", "action.yml", "index.js")
    git(path, "commit", "-m", "moved")
    git(path, "tag", "-f", tag)
    moved = git(path, "rev-parse", "HEAD").stdout.strip()
    if benign == moved:
        raise AssertionError("tag move did not create a new commit")
    # The tag name now points at the attacker's commit. The benign SHA stays put.
    if git(path, "rev-parse", f"refs/tags/{tag}^{{commit}}").stdout.strip() != moved:
        raise AssertionError("tag does not point at the moved commit")
    return benign, moved


def resolve_ref(repo: Path, ref: str) -> str | None:
    """Resolve the way a job-time ref lookup does.

    A full commit SHA is an object id. A tag or branch is read from the ref
    database at resolution time, so a force-moved tag yields the new commit.
    """
    if SHA_RE.match(ref):
        found = git(repo, "rev-parse", "--verify", f"{ref}^{{commit}}", check=False)
        if found.returncode != 0:
            return None
        return found.stdout.strip()
    for candidate in (f"refs/tags/{ref}", f"refs/heads/{ref}", ref):
        found = git(repo, "rev-parse", "--verify", f"{candidate}^{{commit}}", check=False)
        if found.returncode == 0:
            return found.stdout.strip()
    raise AssertionError(f"action ref {ref!r} did not resolve")


def extract_archive(repo: Path, sha: str, dest: Path) -> None:
    """git archive + tar -xzf + unwrap the single top directory, as DownloadRepositoryActionAsync does."""
    with tempfile.TemporaryDirectory(prefix="action-archive-") as tmp:
        root = Path(tmp)
        archive = root / "action.tar.gz"
        subprocess.run(
            ["git", "-C", str(repo), "archive", "--format=tar.gz", "--prefix=action/", "-o", str(archive), sha],
            check=True,
            capture_output=True,
        )
        staging = root / "staging"
        staging.mkdir()
        subprocess.run(["tar", "-xzf", str(archive), "-C", str(staging)], check=True)
        subdirs = [p for p in staging.iterdir() if p.is_dir()]
        if len(subdirs) != 1:
            raise AssertionError(f"archive contained {len(subdirs)} directories")
        dest.rmdir()
        shutil.copytree(subdirs[0], dest)


def substitute(text: str, outputs: dict, ref_name: str) -> str:
    def repl(match: re.Match) -> str:
        expr = match.group(1).strip()
        if expr in ("secrets.GITHUB_TOKEN", "github.token"):
            return JOB_TOKEN
        if expr == "github.ref_name":
            return ref_name
        step_out = re.fullmatch(r"steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)", expr)
        if step_out:
            return outputs.get(step_out.group(1), {}).get(step_out.group(2), "")
        raise AssertionError(f"unsubstituted expression {expr!r}")

    return EXPR_RE.sub(repl, text)


def condition_holds(expr, outputs: dict, ref_name: str) -> bool:
    if expr is None or expr is True:
        return True
    if expr is False:
        return False
    text = substitute(str(expr), outputs, ref_name)
    match = re.fullmatch(r"(.+?)\s*(==|!=)\s*'([^']*)'", text.strip())
    if not match:
        raise AssertionError(f"unparsed step condition {expr!r}")
    left, op, right = match.group(1).strip(), match.group(2), match.group(3)
    left = substitute(left, outputs, ref_name) if "${{" in left else left
    # left may itself be an output path that was not wrapped in ${{ }}.
    step_out = re.fullmatch(r"steps\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_-]+)", left)
    if step_out:
        left = outputs.get(step_out.group(1), {}).get(step_out.group(2), "")
    if left == "github.ref_name":
        left = ref_name
    return left == right if op == "==" else left != right


def contents_permission(workflow: dict, job: dict) -> str:
    perms: dict = {}
    for source in (workflow.get("permissions"), job.get("permissions")):
        if source is None:
            continue
        if isinstance(source, str):
            if source in ("write-all", "write"):
                perms["contents"] = "write"
            elif source in ("read-all", "read"):
                perms.setdefault("contents", "read")
            continue
        if isinstance(source, dict):
            perms.update(source)
    return str(perms.get("contents", ""))


def read_outputs(path: Path) -> dict:
    found = {}
    if not path.exists():
        return found
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            found[key] = value
    return found


class ReleaseApi(threading.Thread):
    """Stand-in for the release endpoint the job token can call.

    contents: write is what the workflow syntax docs say allows creating a release.
    Any other contents permission is refused before a release is stored.
    """

    def __init__(self):
        super().__init__(daemon=True)
        self.releases: list[bytes] = []
        self.contents = "read"
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                auth = self.headers.get("Authorization", "")
                if auth != f"Bearer {JOB_TOKEN}":
                    self.send_response(401)
                elif outer.contents != "write":
                    self.send_response(403)
                else:
                    outer.releases.append(body)
                    self.send_response(201)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, fmt, *args):
                return

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)

    @property
    def url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    def run(self):
        self.server.serve_forever()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


def fake_gh(published: Path) -> str:
    path = published / "bin"
    path.mkdir()
    script = path / "gh"
    script.write_text(
        textwrap.dedent(
            f"""\
            #!/usr/bin/env python3
            import os, shutil, sys
            from pathlib import Path
            args = sys.argv[1:]
            published = Path({str(published)!r})
            token = os.environ.get("GH_TOKEN", "")
            contents = os.environ.get("BLZ_CONTENTS", "")
            if len(args) >= 2 and args[0] == "release" and args[1] == "view":
                sys.exit(1)
            if len(args) >= 4 and args[0] == "release" and args[1] == "create":
                if token != {JOB_TOKEN!r} or contents != "write":
                    sys.stderr.write("release create refused\\n")
                    sys.exit(1)
                asset = Path(args[3])
                published.mkdir(parents=True, exist_ok=True)
                shutil.copy(asset, published / asset.name)
                sys.exit(0)
            sys.stderr.write("unexpected gh invocation\\n")
            sys.exit(1)
            """
        ),
        encoding="utf-8",
    )
    script.chmod(0o755)
    return str(path)


def run_node_action(action_dir: Path, workspace: Path, inputs: dict, extra_env: dict) -> dict:
    manifest_path = action_dir / "action.yml"
    if not manifest_path.exists():
        manifest_path = action_dir / "action.yaml"
    manifest = yaml.load(manifest_path.read_text(encoding="utf-8"), Loader=WorkflowLoader)
    runs = manifest.get("runs") or {}
    using = str(runs.get("using", ""))
    if using not in ("node12", "node16", "node20", "node24"):
        raise AssertionError(f"action runs.using {using!r} is not a node action the runner executes")
    main = runs.get("main")
    if not main:
        raise AssertionError("node action has no main")
    script = action_dir / main
    if not script.is_file():
        raise AssertionError(f"missing action entrypoint {script}")
    defined = manifest.get("inputs") or {}
    merged = dict(inputs)
    for name, meta in defined.items():
        if name in merged or not isinstance(meta, dict):
            continue
        default = meta.get("default", "")
        merged[name] = substitute(str(default), {}, extra_env.get("GITHUB_REF_NAME", "master"))
    output = Path(extra_env["GITHUB_OUTPUT"])
    env = os.environ.copy()
    env.update(extra_env)
    env["GITHUB_WORKSPACE"] = str(workspace)
    for key, value in merged.items():
        env[f"INPUT_{key.replace(' ', '_').upper()}"] = value
    proc = subprocess.run(
        ["node", str(script)],
        cwd=workspace,
        env=env,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise AssertionError(f"action exited {proc.returncode}: {proc.stderr}")
    return read_outputs(output)


def publishing_jobs(workflow: dict) -> list[tuple[str, dict]]:
    found = []
    for name, job in workflow["jobs"].items():
        if not isinstance(job, dict):
            continue
        blob = yaml.dump(job.get("steps") or [])
        if "gh release create" in blob or "blazium_games-" in blob:
            found.append((name, job))
    return found


def simulate(workflow: dict, action_repos: dict[str, Path] | None = None) -> dict:
    ref_name = "master"
    api = ReleaseApi()
    api.start()
    published = Path(tempfile.mkdtemp(prefix="published-"))
    gh_dir = fake_gh(published)
    executed = []
    try:
        for job_name, job in publishing_jobs(workflow):
            if not condition_holds(job.get("if"), {}, ref_name):
                continue
            api.contents = contents_permission(workflow, job)
            workspace = Path(tempfile.mkdtemp(prefix=f"ws-{job_name}-"))
            shutil.copytree(ROOT / "addons", workspace / "addons")
            shutil.copy(ROOT / "LICENSE", workspace / "LICENSE")
            outputs: dict[str, dict] = {}
            benign_marker = workspace / ".benign-actions"
            for step in job.get("steps") or []:
                if not isinstance(step, dict):
                    continue
                if not condition_holds(step.get("if"), outputs, ref_name):
                    continue
                step_id = step.get("id")
                step_output = workspace / f".output-{step_id or 'step'}"
                if "uses" in step:
                    kind, name, ref, rel = parse_uses(str(step["uses"]))
                    if kind == "docker":
                        # A mutable image tag is the same supply path as a moved action tag.
                        target = workspace / "addons" / "blazium_games" / "blazium_games.gd"
                        target.write_text(target.read_text(encoding="utf-8") + f"\n# {CANARY}\n", encoding="utf-8")
                        executed.append(str(step["uses"]))
                        continue
                    if kind == "local":
                        continue
                    repo = (action_repos or {}).get(name)
                    owned = False
                    if repo is None:
                        if SHA_RE.match(ref):
                            # The workflow named a commit object. A later tag move is a different ref.
                            executed.append(f"{name}@{ref} pinned")
                            continue
                        repo = Path(tempfile.mkdtemp(prefix="action-repo-"))
                        init_action_repo(repo, ref)
                        owned = True
                    sha = resolve_ref(repo, ref)
                    if sha is None:
                        executed.append(f"{name}@{ref} pinned-missing")
                        continue
                    action_dir = Path(tempfile.mkdtemp(prefix="action-"))
                    extract_archive(repo, sha, action_dir)
                    if rel:
                        action_dir = action_dir / rel
                    raw_inputs = step.get("with") or {}
                    inputs = {
                        key: substitute(str(value), outputs, ref_name)
                        for key, value in raw_inputs.items()
                    }
                    node_outputs = run_node_action(
                        action_dir,
                        workspace,
                        inputs,
                        {
                            "GITHUB_OUTPUT": str(step_output),
                            "GITHUB_REF_NAME": ref_name,
                            "BLZ_RELEASE_API": api.url,
                            "BENIGN_MARKER": str(benign_marker),
                            "BENIGN_NAME": f"{name}@{sha}",
                        },
                    )
                    executed.append(f"{name}@{ref}->{sha}")
                    if step_id:
                        outputs[step_id] = node_outputs
                    if owned:
                        shutil.rmtree(repo, ignore_errors=True)
                    continue
                if "run" not in step:
                    continue
                script = substitute(str(step["run"]), outputs, ref_name)
                env = os.environ.copy()
                env["PATH"] = gh_dir + os.pathsep + env.get("PATH", "")
                env["GITHUB_OUTPUT"] = str(step_output)
                env["GITHUB_STEP_SUMMARY"] = str(workspace / ".summary")
                env["BLZ_CONTENTS"] = api.contents
                env["GITHUB_WORKSPACE"] = str(workspace)
                for key, value in (step.get("env") or {}).items():
                    env[str(key)] = substitute(str(value), outputs, ref_name)
                proc = subprocess.run(
                    ["bash", "--noprofile", "--norc", "-c", script],
                    cwd=workspace,
                    env=env,
                    text=True,
                    capture_output=True,
                )
                if proc.returncode != 0:
                    raise AssertionError(
                        f"step {step.get('name') or step_id} exited {proc.returncode}\n{proc.stdout}\n{proc.stderr}"
                    )
                if step_id:
                    outputs[step_id] = read_outputs(step_output)
        zips = list(published.glob("*.zip"))
        published_zip = zips[0].read_bytes() if zips else None
        return {
            "published_zip": published_zip,
            "api_bodies": list(api.releases),
            "executed": executed,
        }
    finally:
        api.stop()


def assert_release_is_clean(result: dict) -> None:
    blob = result["published_zip"]
    problems = []
    if blob is None:
        problems.append("publish job did not upload a zip")
    else:
        with zipfile.ZipFile(io.BytesIO(blob)) as archive:
            names = archive.namelist()
            script = archive.read("addons/blazium_games/blazium_games.gd")
        if "addons/blazium_games/blazium_games.gd" not in names or b"class_name BlaziumGames" not in script:
            problems.append("published zip is not the addon players install")
        if CANARY.encode() in blob or CANARY.encode() in script:
            problems.append("published zip contains the moved action's player-script marker")
    for body in result["api_bodies"]:
        if CANARY.encode() in body:
            problems.append("job token created a release from the moved action")
            break
    if problems:
        raise AssertionError("; ".join(problems) + f" executed={result['executed']}")


def test_sha_pin_ignores_a_moved_tag() -> None:
    """Control: the same harness publishes a clean zip when both actions are commit SHAs."""
    text = WORKFLOW.read_text(encoding="utf-8")
    workflow = load_workflow(text)
    jobs = publishing_jobs(workflow)
    if len(jobs) != 1:
        raise AssertionError(f"expected one publishing job, found {[name for name, _ in jobs]}")
    repos = {}
    pins = {}
    with tempfile.TemporaryDirectory(prefix="pin-repos-") as tmp:
        base = Path(tmp)
        for step in jobs[0][1]["steps"]:
            if "uses" not in step:
                continue
            kind, name, ref, _rel = parse_uses(str(step["uses"]))
            if kind != "github" or SHA_RE.match(ref):
                continue
            repo = base / name.replace("/", "__")
            benign, _moved = init_action_repo(repo, ref)
            repos[name] = repo
            pins[str(step["uses"])] = f"{name}@{benign}"
        pinned = text
        for old, new in pins.items():
            pinned = pinned.replace(f"uses: {old}", f"uses: {new}", 1)
        if pinned == text:
            raise AssertionError("control did not rewrite any action ref")
        result = simulate(load_workflow(pinned), repos)
    assert_release_is_clean(result)
    ran = [line for line in result["executed"] if "->" in line]
    if len(ran) != len(pins):
        raise AssertionError(f"pinned actions did not execute their SHAs: {result['executed']}")
    for line in ran:
        sha = line.rsplit("->", 1)[1]
        if not SHA_RE.match(sha):
            raise AssertionError(f"executed ref was not a commit {line}")
    for body in result["api_bodies"]:
        if CANARY.encode() in body:
            raise AssertionError("pinned action still called the release API with the marker")


def test_moved_tag_cannot_reach_the_published_zip() -> None:
    """The workflow on disk. Fails while a publishing step uses a tag or branch."""
    workflow = load_workflow(WORKFLOW.read_text(encoding="utf-8"))
    result = simulate(workflow)
    assert_release_is_clean(result)


def main() -> int:
    tests = [
        test_sha_pin_ignores_a_moved_tag,
        test_moved_tag_cannot_reach_the_published_zip,
    ]
    failed = False
    for test in tests:
        try:
            test()
        except AssertionError as exc:
            failed = True
            print(f"FAIL {test.__name__}: {exc}")
        else:
            print(f"PASS {test.__name__}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
