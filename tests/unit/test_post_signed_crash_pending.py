import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from tests.unit.technocore_post_test_support import install_trusted_git


TEST_SEED = "0" * 64


def _helper_env(tmp_path, port, repo):
    home = tmp_path / "home"
    seed_dir = home / ".config" / "technocore"
    seed_dir.mkdir(parents=True)
    seed_file = seed_dir / "sign_seed"
    seed_file.write_text(TEST_SEED + "\n")
    seed_file.chmod(0o600)

    bin_dir = tmp_path / "git-bin"
    bin_dir.mkdir()
    install_trusted_git(bin_dir, repo)

    env = os.environ.copy()
    env["HOME"] = str(home)
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["TECHNOCORE_BASE_URL"] = f"http://127.0.0.1:{port}"
    return home, env


def test_pending_attempt_is_durable_before_post_survives_process_death(tmp_path) -> None:
    repo = Path(__file__).resolve().parents[2]
    helper = repo / "post_signed.sh"
    received = []
    first_received = threading.Event()
    release_first = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers["Content-Length"])
            received.append(json.loads(self.rfile.read(length)))
            if len(received) == 1:
                first_received.set()
                release_first.wait(timeout=5)
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            messages = [
                {
                    "from": item["did"],
                    "sig": item["sig"],
                    "nonce": int(item["nonce"]),
                    "text": item["text"],
                }
                for item in received
            ]
            body = json.dumps({"messages": messages}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    home, env = _helper_env(tmp_path, server.server_port, repo)

    first = None
    try:
        first = subprocess.Popen(
            ["bash", str(helper), "test-room", "survive crash"],
            cwd=repo,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert first_received.wait(timeout=5)

        pending_files = list((home / ".config" / "technocore" / "nonces").glob("*.pending"))
        assert len(pending_files) == 1, "attempt must be durable before request bytes are sent"

        first.kill()
        first.communicate(timeout=5)
        release_first.set()

        second = subprocess.run(
            ["bash", str(helper), "test-room", "survive crash"],
            cwd=repo,
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )

        assert second.returncode == 0, second.stderr
        assert "Previous outcome-unknown post is present in the room" in second.stdout
        assert len(received) == 1, "restart must reconcile the prior attempt instead of reposting"
        assert not list((home / ".config" / "technocore" / "nonces").glob("*.pending"))
    finally:
        if first is not None and first.poll() is None:
            first.kill()
            first.communicate(timeout=5)
        release_first.set()
        server.shutdown()
        server.server_close()
