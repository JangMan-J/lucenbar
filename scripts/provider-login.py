#!/usr/bin/env python3
"""Drive a provider CLI's login flow from the widget, without a terminal.

start   spawns the provider's login command detached, under a pseudo-terminal
        or native OAuth runner, so prompts behave as they would in a shell.
        Output goes to a log; a FIFO carries anything the user types back
        (pasted auth codes).
status  reports what the flow is waiting on: the browser URL, a device code,
        or a pasted code; and whether it finished.
submit  writes a code into the running flow.
cancel  ends the flow.

Every reply is one JSON object on stdout.
"""
import argparse
import base64
import datetime
import errno
import hashlib
import http.server
import json
import os
import pty
import re
import secrets
import select
import shutil
import signal
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid

COMMANDS = {
    "codex": ["codex", "login"],
    "claude": ["claude", "auth", "login"],
    "antigravity": ["antigravity-google-oauth"],
    "grok": ["grok-xai-device-oauth"],
    "muse": ["muse", "login"],
    "pi": ["pi-radius-oauth"],
}
NATIVE_RUNNERS = {"antigravity", "grok", "pi"}
EXTRA_PATH = [os.path.expanduser(p) for p in ("~/.local/bin", "~/.npm-global/bin", "~/.cargo/bin", "~/bin")]
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\r")
URL = re.compile(r"https?://[^\s'\"<>)\]]+")
DEVICE_CODE = re.compile(r"\b([A-Z0-9]{4,6}-[A-Z0-9]{4,6})\b")
DONE = re.compile(r"(logged in|login successful|successfully (logged in|authenticated)|authenticated successfully|you are now signed in|signed in as)", re.I)
NEEDS_CODE = re.compile(r"(paste (the )?(authorization )?code|enter the code|paste it here|authorization code here)", re.I)
MAX_LOG = 256 * 1024
USER_AGENT = "pi-coding-agent/1.0"


def session_dir(provider):
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    path = os.path.join(base, "lucenbar", "login", provider)
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def read(path, default=""):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as stream:
            return stream.read()
    except OSError:
        return default


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError as error:
        return error.errno == errno.EPERM


def clean(text):
    return ANSI.sub("", text)


def resolve(command):
    path = os.environ.get("PATH", "")
    env_path = ":".join([p for p in EXTRA_PATH if os.path.isdir(p)] + [path])
    executable = shutil.which(command[0], path=env_path)
    return (executable, env_path) if executable else (None, env_path)


def save_pi_auth_entry(provider_key, entry):
    auth_dir = os.path.expanduser("~/.pi/agent")
    os.makedirs(auth_dir, mode=0o700, exist_ok=True)
    auth_path = os.path.join(auth_dir, "auth.json")
    store = {}
    if os.path.exists(auth_path):
        try:
            with open(auth_path, "r", encoding="utf-8") as stream:
                store = json.load(stream)
        except Exception:
            store = {}
    existing = store.get(provider_key)
    if isinstance(existing, dict):
        merged = dict(existing)
        merged.update(entry)
        store[provider_key] = merged
    else:
        store[provider_key] = entry
    tmp_path = auth_path + ".tmp." + str(os.getpid())
    with open(tmp_path, "w", encoding="utf-8") as stream:
        os.chmod(tmp_path, 0o600)
        json.dump(store, stream, indent=2)
    os.replace(tmp_path, auth_path)


def runner(provider, command, env_path, directory):
    """Child side of start: own the pty, mirror output, feed input, record exit."""
    os.setsid()
    log_path = os.path.join(directory, "log")
    fifo_path = os.path.join(directory, "input")
    exit_path = os.path.join(directory, "exit")
    noop_bin = os.path.join(directory, "bin")
    os.makedirs(noop_bin, mode=0o700, exist_ok=True)
    noop_xdg = os.path.join(noop_bin, "xdg-open")
    with open(noop_xdg, "w", encoding="utf-8") as stream:
        stream.write("#!/bin/sh\nexit 0\n")
    os.chmod(noop_xdg, 0o700)
    master, slave = pty.openpty()
    env = dict(os.environ)
    env["PATH"] = noop_bin + ":" + env_path
    env["BROWSER"] = "true"
    env["TERM"] = "dumb"
    env.pop("NO_COLOR", None)
    env["NO_COLOR"] = "1"
    child = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, env=env,
                             close_fds=True, start_new_session=False)
    os.close(slave)
    with open(os.path.join(directory, "pid"), "w", encoding="utf-8") as stream:
        stream.write(str(child.pid))
    fifo = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
    enter_sent = False
    with open(log_path, "ab", buffering=0) as log:
        written = 0
        while True:
            try:
                ready, _, _ = select.select([master, fifo], [], [], 0.5)
            except InterruptedError:
                ready = []
            for descriptor in ready:
                if descriptor == master:
                    try:
                        chunk = os.read(master, 4096)
                    except OSError:
                        chunk = b""
                    if chunk and written < MAX_LOG:
                        log.write(chunk)
                        written += len(chunk)
                        if not enter_sent and b"Press Enter to open" in chunk:
                            try:
                                os.write(master, b"\n")
                                enter_sent = True
                            except OSError:
                                pass
                elif descriptor == fifo:
                    try:
                        data = os.read(fifo, 4096)
                    except OSError:
                        data = b""
                    if data:
                        os.write(master, data)
                    else:
                        os.close(fifo)
                        fifo = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
            if child.poll() is not None:
                while True:
                    try:
                        chunk = os.read(master, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                    if written < MAX_LOG:
                        log.write(chunk)
                        written += len(chunk)
                break
    with open(exit_path, "w", encoding="utf-8") as stream:
        stream.write(str(child.returncode))
    os._exit(0)


def pkce_callback_server(host, port, callback_path, expected_state, finish):
    result_box = {"code": None, "error": None}

    class CallbackHandler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != callback_path:
                self.send_response(404)
                self.end_headers()
                return
            qs = urllib.parse.parse_qs(parsed.query)
            if qs.get("state", [""])[0] != expected_state:
                result_box["error"] = "OAuth state mismatch"
                self.send_response(400)
                self.end_headers()
                return
            if "error" in qs:
                result_box["error"] = qs["error"][0]
                self.send_response(400)
                self.end_headers()
                return
            code = qs.get("code", [""])[0]
            if not code:
                result_box["error"] = "Missing authorization code"
                self.send_response(400)
                self.end_headers()
                return
            result_box["code"] = code
            body = b"<html><body><p>Authentication complete. You may close this tab.</p></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    try:
        http.server.HTTPServer.allow_reuse_address = True
        server = http.server.HTTPServer((host, port), CallbackHandler)
        server.timeout = 1.0
    except Exception as exc:
        finish(1, f"Could not listen on {host}:{port}: {exc}")
        return None

    deadline = time.time() + 300
    try:
        while time.time() < deadline and not result_box["code"] and not result_box["error"]:
            server.handle_request()
    finally:
        server.server_close()

    if result_box["error"] or not result_box["code"]:
        finish(1, result_box["error"] or "Timed out waiting for browser callback")
        return None
    return result_box["code"]


def radius_runner(directory):
    """Run the Radius PKCE + 127.0.0.1:1456/oauth/callback login flow."""
    os.setsid()
    log_path = os.path.join(directory, "log")
    exit_path = os.path.join(directory, "exit")
    with open(os.path.join(directory, "pid"), "w", encoding="utf-8") as stream:
        stream.write(str(os.getpid()))

    def finish(code, message=""):
        if message:
            with open(log_path, "ab") as log:
                log.write((message + "\n").encode("utf-8"))
        with open(exit_path, "w", encoding="utf-8") as stream:
            stream.write(str(code))
        os._exit(0)

    gateway = (os.environ.get("PI_RADIUS_GATEWAY") or "https://radius.pi.dev").rstrip("/")
    try:
        req = urllib.request.Request(
            gateway + "/v1/oauth",
            headers={"Accept": "application/json", "User-Agent": USER_AGENT},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            discovery = json.loads(resp.read().decode("utf-8"))
        auth_endpoint = discovery["authorizationEndpoint"]
    except Exception:
        auth_endpoint = "https://radius.earendil.com/oauth/authorize"

    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode("ascii")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")
    state = str(uuid.uuid4())
    redirect_uri = "http://127.0.0.1:1456/oauth/callback"
    params = urllib.parse.urlencode({
        "response_type": "code",
        "client_id": "pi-gateway",
        "redirect_uri": redirect_uri,
        "scope": "gateway offline_access",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "handoff": "url",
        "state": state,
    })
    authorize_url = f"{auth_endpoint}?{params}"
    with open(log_path, "wb") as log:
        log.write(f"Open {authorize_url}\n".encode("utf-8"))

    code = pkce_callback_server("127.0.0.1", 1456, "/oauth/callback", state, finish)
    if not code:
        return

    try:
        token_body = urllib.parse.urlencode({
            "grant_type": "authorization_code",
            "client_id": "pi-gateway",
            "redirect_uri": redirect_uri,
            "code": code,
            "code_verifier": verifier,
        }).encode("utf-8")
        token_req = urllib.request.Request(
            gateway + "/v1/oauth/token",
            data=token_body,
            headers={
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": USER_AGENT,
            },
            method="POST",
        )
        with urllib.request.urlopen(token_req, timeout=15) as resp:
            token_data = json.loads(resp.read().decode("utf-8"))
        entry = {
            "type": "oauth",
            "access": token_data["access_token"],
            "refresh": token_data["refresh_token"],
            "expires": int(time.time() * 1000) + int(token_data.get("expires_in", 3600)) * 1000 - 60000,
        }
        if token_data.get("scope"):
            entry["scope"] = token_data["scope"]
        save_pi_auth_entry("radius", entry)
        finish(0, "Logged in")
    except Exception as exc:
        finish(1, f"Token exchange failed: {exc}")


def antigravity_runner(directory):
    """Run the Antigravity Google OAuth PKCE + localhost:51121/oauth-callback flow."""
    os.setsid()
    log_path = os.path.join(directory, "log")
    exit_path = os.path.join(directory, "exit")
    with open(os.path.join(directory, "pid"), "w", encoding="utf-8") as stream:
        stream.write(str(os.getpid()))

    def finish(code, message=""):
        if message:
            with open(log_path, "ab") as log:
                log.write((message + "\n").encode("utf-8"))
        with open(exit_path, "w", encoding="utf-8") as stream:
            stream.write(str(code))
        os._exit(0)

    # Google's public Antigravity desktop OAuth client (installed-app credentials are
    # not confidential), as used by pi-antigravity (MIT, Rahul Arya) and pi-ai.
    client_id = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    client_secret = "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"
    redirect_uri = "http://localhost:51121/oauth-callback"
    scopes = " ".join(
        f"https://www.googleapis.com/auth/{s}"
        for s in ("aicode", "cloud-platform", "userinfo.email", "userinfo.profile", "cclog", "experimentsandconfigs")
    )
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode("ascii")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")
    state = str(uuid.uuid4())
    params = urllib.parse.urlencode({
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "scope": scopes,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
        "access_type": "offline",
        "prompt": "consent",
    })
    authorize_url = f"https://accounts.google.com/o/oauth2/v2/auth?{params}"
    with open(log_path, "wb") as log:
        log.write(f"Open {authorize_url}\n".encode("utf-8"))

    code = pkce_callback_server("127.0.0.1", 51121, "/oauth-callback", state, finish)
    if not code:
        return

    try:
        token_body = urllib.parse.urlencode({
            "client_id": client_id,
            "client_secret": client_secret,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirect_uri,
            "code_verifier": verifier,
        }).encode("utf-8")
        token_req = urllib.request.Request(
            "https://oauth2.googleapis.com/token",
            data=token_body,
            headers={
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": USER_AGENT,
            },
            method="POST",
        )
        with urllib.request.urlopen(token_req, timeout=15) as resp:
            token_data = json.loads(resp.read().decode("utf-8"))
        access = token_data["access_token"]
        refresh = token_data.get("refresh_token", "")
        expires = int(time.time() * 1000) + max(0, int(token_data.get("expires_in", 3600)) - 300) * 1000
        email = ""
        try:
            u_req = urllib.request.Request(
                "https://www.googleapis.com/oauth2/v1/userinfo?alt=json",
                headers={"Authorization": f"Bearer {access}", "User-Agent": USER_AGENT},
            )
            with urllib.request.urlopen(u_req, timeout=10) as u_resp:
                u_data = json.loads(u_resp.read().decode("utf-8"))
                if isinstance(u_data.get("email"), str):
                    email = u_data["email"]
        except Exception:
            pass
        entry = {
            "type": "oauth",
            "access": access,
            "expires": expires,
        }
        if refresh:
            entry["refresh"] = refresh
        if email:
            entry["email"] = email
        save_pi_auth_entry("antigravity", entry)
        finish(0, "Logged in")
    except Exception as exc:
        finish(1, f"Antigravity OAuth failed: {exc}")


def grok_runner(directory):
    """Run the xAI / Grok device-code flow via https://accounts.x.ai/oauth2/device/."""
    os.setsid()
    log_path = os.path.join(directory, "log")
    exit_path = os.path.join(directory, "exit")
    with open(os.path.join(directory, "pid"), "w", encoding="utf-8") as stream:
        stream.write(str(os.getpid()))

    def finish(code, message=""):
        if message:
            with open(log_path, "ab") as log:
                log.write((message + "\n").encode("utf-8"))
        with open(exit_path, "w", encoding="utf-8") as stream:
            stream.write(str(code))
        os._exit(0)

    client_id = "b1a00492-073a-47ea-816f-4c329264a828"
    scope = "openid profile email offline_access grok-cli:access api:access"
    try:
        body = urllib.parse.urlencode({
            "client_id": client_id,
            "scope": scope,
            "referrer": "pi",
        }).encode("utf-8")
        req = urllib.request.Request(
            "https://auth.x.ai/oauth2/device/code",
            data=body,
            headers={
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": USER_AGENT,
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=12) as resp:
            device = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:
        finish(1, f"Could not start Grok device login: {exc}")
        return

    device_code = str(device.get("device_code") or "")
    user_code = str(device.get("user_code") or "")
    verification_url = str(device.get("verification_uri_complete") or device.get("verification_uri") or "https://accounts.x.ai/oauth2/device/")
    interval = max(2, int(device.get("interval") or 5))
    expires_in = max(60, int(device.get("expires_in") or 600))
    if not device_code or not user_code:
        finish(1, "Invalid device authorization response from xAI")
        return

    with open(log_path, "wb") as log:
        log.write(f"Open {verification_url}\nCode: {user_code}\n".encode("utf-8"))

    deadline = time.time() + expires_in
    while time.time() < deadline:
        time.sleep(interval)
        try:
            poll_body = urllib.parse.urlencode({
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": client_id,
                "device_code": device_code,
            }).encode("utf-8")
            poll_req = urllib.request.Request(
                "https://auth.x.ai/oauth2/token",
                data=poll_body,
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "User-Agent": USER_AGENT,
                },
                method="POST",
            )
            with urllib.request.urlopen(poll_req, timeout=12) as resp:
                token_data = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as err:
            try:
                err_body = json.loads(err.read().decode("utf-8"))
            except Exception:
                err_body = {}
            err_code = err_body.get("error")
            if err_code == "authorization_pending":
                continue
            if err_code == "slow_down":
                interval += 5
                continue
            finish(1, f"Grok device login failed: {err_code or err.code}")
            return
        except Exception as exc:
            finish(1, f"Grok device login error: {exc}")
            return

        access = str(token_data.get("access_token") or "")
        refresh = str(token_data.get("refresh_token") or "")
        expires_sec = int(token_data.get("expires_in") or 3600)
        if not access:
            finish(1, "Grok token response missing access_token")
            return

        now = datetime.datetime.now(datetime.timezone.utc)
        expires_dt = now + datetime.timedelta(seconds=expires_sec)
        save_pi_auth_entry("xai", {
            "type": "oauth",
            "access": access,
            "refresh": refresh,
            "expires": int(time.time() * 1000) + expires_sec * 1000 - 300000,
        })

        grok_dir = os.path.expanduser("~/.grok")
        os.makedirs(grok_dir, mode=0o700, exist_ok=True)
        grok_auth_path = os.path.join(grok_dir, "auth.json")
        grok_store = {}
        if os.path.exists(grok_auth_path):
            try:
                with open(grok_auth_path, "r", encoding="utf-8") as stream:
                    grok_store = json.load(stream)
            except Exception:
                grok_store = {}
        slot_key = f"https://auth.x.ai::{client_id}"
        slot = grok_store.get(slot_key) if isinstance(grok_store.get(slot_key), dict) else {}
        slot["key"] = access
        if refresh:
            slot["refresh_token"] = refresh
        slot["auth_mode"] = "oidc"
        slot["oidc_issuer"] = "https://auth.x.ai"
        slot["oidc_client_id"] = client_id
        slot["create_time"] = now.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        slot["expires_at"] = expires_dt.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        grok_store[slot_key] = slot
        tmp_path = grok_auth_path + ".tmp." + str(os.getpid())
        with open(tmp_path, "w", encoding="utf-8") as stream:
            os.chmod(tmp_path, 0o600)
            json.dump(grok_store, stream, indent=2)
        os.replace(tmp_path, grok_auth_path)
        finish(0, "Logged in")
        return

    finish(1, "Timed out waiting for Grok device approval")


def start(provider):
    command = COMMANDS.get(provider)
    if not command:
        return {"state": "unsupported"}
    if provider not in NATIVE_RUNNERS:
        executable, env_path = resolve(command)
        if not executable:
            return {"state": "missing", "tool": command[0]}
    else:
        executable, env_path = None, ""
    # Always cancel any stale/prior attempt so clicking Log in starts fresh and opens the browser.
    cancel(provider)
    directory = session_dir(provider)
    fifo_path = os.path.join(directory, "input")
    if not os.path.exists(fifo_path):
        os.mkfifo(fifo_path, 0o600)
    with open(os.path.join(directory, "started"), "w", encoding="utf-8") as stream:
        stream.write(str(time.time()))
    if os.fork() == 0:
        # double fork so the runner outlives the widget's bounded helper call
        if os.fork() == 0:
            if provider == "pi":
                radius_runner(directory)
            elif provider == "antigravity":
                antigravity_runner(directory)
            elif provider == "grok":
                grok_runner(directory)
            else:
                runner(provider, [executable] + command[1:], env_path, directory)
        os._exit(0)
    for _ in range(40):
        time.sleep(0.1)
        st = status(provider)
        if st.get("url") or st.get("state") in ("done", "failed"):
            return st
    return status(provider)


def status(provider):
    if provider not in COMMANDS:
        return {"state": "unsupported"}
    directory = session_dir(provider)
    pid_text = read(os.path.join(directory, "pid")).strip()
    log = clean(read(os.path.join(directory, "log")))
    exit_text = read(os.path.join(directory, "exit")).strip()
    tail = "\n".join([line for line in log.splitlines() if line.strip()][-6:])[-1200:]
    # CLIs print a local server line before the real link; the last URL wins.
    urls = URL.findall(log)
    url = urls[-1].rstrip(".,") if urls else ""
    code_match = DEVICE_CODE.search(log)
    device_code = code_match.group(1) if code_match else ""
    result = {"state": "absent", "url": url, "deviceCode": device_code,
              "needsCode": bool(NEEDS_CODE.search(log)), "tail": tail, "tool": COMMANDS[provider][0]}
    if not pid_text and not exit_text:
        return result
    if exit_text:
        code = int(exit_text) if exit_text.lstrip("-").isdigit() else 1
        result["exitCode"] = code
        result["state"] = "done" if code == 0 or DONE.search(log) else "failed"
        return result
    pid = int(pid_text) if pid_text.isdigit() else 0
    if pid and alive(pid):
        result["state"] = "needs_code" if result["needsCode"] else "waiting"
        if DONE.search(log):
            result["state"] = "done"
        return result
    result["state"] = "failed"
    return result


def submit(provider, code):
    if provider not in COMMANDS:
        return {"state": "unsupported"}
    code = (code or "").strip()
    if not code or len(code) > 512 or any(ord(c) < 32 for c in code):
        return {"state": "invalid_code"}
    fifo_path = os.path.join(session_dir(provider), "input")
    try:
        descriptor = os.open(fifo_path, os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        return {"state": "absent"}
    try:
        os.write(descriptor, (code + "\n").encode("utf-8"))
    finally:
        os.close(descriptor)
    time.sleep(0.5)
    return status(provider)


def cancel(provider):
    if provider not in COMMANDS:
        return {"state": "unsupported"}
    directory = session_dir(provider)
    pid_text = read(os.path.join(directory, "pid")).strip()
    if pid_text.isdigit():
        try:
            os.killpg(int(pid_text), signal.SIGTERM)
        except OSError:
            try:
                os.kill(int(pid_text), signal.SIGTERM)
            except OSError:
                pass
    for name in ("log", "exit", "pid", "started"):
        try:
            os.unlink(os.path.join(directory, name))
        except OSError:
            pass
    return {"state": "absent"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "status", "submit", "cancel"))
    parser.add_argument("--provider", required=True)
    parser.add_argument("--code", default="")
    args = parser.parse_args()
    provider = re.sub(r"[^a-z0-9]", "", args.provider.lower())[:40]
    signal.alarm(30)
    if args.action == "start":
        result = start(provider)
    elif args.action == "status":
        result = status(provider)
    elif args.action == "submit":
        result = submit(provider, args.code)
    else:
        result = cancel(provider)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
