#!/usr/bin/env python3
"""Fetch live Radius organization credit balance and budget usage for CodexBar."""
import datetime
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request

EXTRA_PATH = [os.path.expanduser(p) for p in ("~/.local/bin", "~/.npm-global/bin", "~/.cargo/bin", "~/bin")]


def load_token(gateway):
    env_key = (os.environ.get("RADIUS_API_KEY") or "").strip()
    if env_key:
        return env_key, "api"
    path = os.environ.get("PATH", "")
    env_path = ":".join([p for p in EXTRA_PATH if os.path.isdir(p)] + [path])
    pi_bin = shutil.which("pi", path=env_path)
    if pi_bin:
        try:
            env = dict(os.environ)
            env["PATH"] = env_path
            out = subprocess.check_output(
                [pi_bin, "auth", "print-bearer-token", "--provider", "radius"],
                env=env,
                stderr=subprocess.DEVNULL,
                timeout=10,
                text=True,
            ).strip()
            if out:
                return out, "oauth"
        except Exception:
            pass
    auth_path = os.path.expanduser("~/.pi/agent/auth.json")
    try:
        with open(auth_path, "r", encoding="utf-8") as stream:
            store = json.load(stream)
    except Exception:
        return "", ""
    cred = store.get("radius")
    if not isinstance(cred, dict):
        return "", ""
    if cred.get("type") == "api_key" and cred.get("key"):
        return str(cred["key"]).strip(), "api"
    access = str(cred.get("access") or "").strip()
    refresh = str(cred.get("refresh") or "").strip()
    expires = float(cred.get("expires") or 0)
    if access and (expires <= 0 or expires > time.time() * 1000 + 30000):
        return access, "oauth"
    if refresh:
        try:
            body = urllib.parse.urlencode({
                "grant_type": "refresh_token",
                "client_id": "pi-gateway",
                "refresh_token": refresh,
            }).encode("utf-8")
            req = urllib.request.Request(
                gateway + "/v1/oauth/token",
                data=body,
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "User-Agent": "pi-coding-agent/1.0",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                token_data = json.loads(resp.read().decode("utf-8"))
            new_access = str(token_data.get("access_token") or "").strip()
            if new_access:
                cred["access"] = new_access
                if token_data.get("refresh_token"):
                    cred["refresh"] = token_data["refresh_token"]
                cred["expires"] = int(time.time() * 1000) + int(token_data.get("expires_in", 3600)) * 1000 - 60000
                store["radius"] = cred
                tmp_path = auth_path + ".tmp." + str(os.getpid())
                with open(tmp_path, "w", encoding="utf-8") as stream:
                    os.chmod(tmp_path, 0o600)
                    json.dump(store, stream, indent=2)
                os.replace(tmp_path, auth_path)
                return new_access, "oauth"
        except Exception:
            pass
    return access, "oauth"


def mcp_call(gateway, token, tool_name):
    body = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": {}},
    }
    req = urllib.request.Request(
        gateway + "/mcp",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": "pi-coding-agent/1.0",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=12) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    result = payload.get("result") or {}
    structured = result.get("structuredContent")
    if isinstance(structured, dict):
        return structured
    for item in result.get("content") or []:
        if isinstance(item, dict) and item.get("type") == "text" and item.get("text"):
            try:
                return json.loads(item["text"])
            except Exception:
                pass
    return {}


def fmt_usd(amount):
    return f"${float(amount or 0):.2f}"


def main():
    gateway = (os.environ.get("PI_RADIUS_GATEWAY") or "https://radius.pi.dev").rstrip("/")
    token, source = load_token(gateway)
    if not token:
        print(json.dumps([{
            "provider": "pi",
            "source": "oauth",
            "error": {"code": 1, "kind": "auth", "message": "Not signed in to Radius. Click Log in to connect your account."},
        }]))
        sys.exit(1)

    try:
        billing = mcp_call(gateway, token, "billing_summary_read")
    except Exception as exc:
        print(json.dumps([{
            "provider": "pi",
            "source": source or "oauth",
            "error": {"code": 1, "kind": "provider", "message": f"Could not read Radius billing: {exc}"},
        }]))
        sys.exit(1)

    org_name = ""
    try:
        ctx = mcp_call(gateway, token, "context_read")
        org = ctx.get("organization") if isinstance(ctx, dict) else None
        if isinstance(org, dict) and org.get("name"):
            org_name = str(org["name"])
    except Exception:
        pass

    balance = billing.get("balance") if isinstance(billing.get("balance"), dict) else {}
    current_period = billing.get("current_period") if isinstance(billing.get("current_period"), dict) else {}
    all_time = billing.get("all_time") if isinstance(billing.get("all_time"), dict) else {}

    available = float(balance.get("available") if balance.get("available") is not None else 0.0)
    credit_balance = float(balance.get("credit_balance") if balance.get("credit_balance") is not None else available)
    reserved = float(balance.get("reserved") or 0.0)
    month_charged = float(current_period.get("actual_charged") or 0.0)
    all_credited = float(all_time.get("credited") or 0.0)

    total_pool = max(all_credited, credit_balance + month_charged, available)
    if total_pool > 0:
        used_percent = max(0.0, min(100.0, ((total_pool - available) / total_pool) * 100.0))
    else:
        used_percent = 100.0 if available <= 0 else 0.0

    as_of = str(billing.get("as_of") or balance.get("updated_at") or datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"))

    detail_rows = [
        {"label": "Available balance", "value": fmt_usd(available)},
        {"label": "Credit balance", "value": fmt_usd(credit_balance)},
        {"label": "This month spend", "value": fmt_usd(month_charged)},
        {"label": "All-time credited", "value": fmt_usd(all_credited)},
    ]
    if reserved > 0:
        detail_rows.insert(2, {"label": "Reserved", "value": fmt_usd(reserved)})

    record = {
        "provider": "pi",
        "displayName": "Radius",
        "source": source or "oauth",
        "credits": {
            "remaining": available,
            "updatedAt": as_of,
        },
        "rateWindowLabels": {
            "primary": f"Balance ({fmt_usd(available)})",
        },
        "usage": {
            "dataConfidence": "exact",
            "updatedAt": as_of,
            "identity": {
                "accountOrganization": org_name,
                "loginMethod": "OAuth" if source == "oauth" else "API key",
            },
            "primary": {
                "usedPercent": used_percent,
                "resetDescription": f"{fmt_usd(available)} of {fmt_usd(total_pool)} left",
            },
            "secondary": None,
            "tertiary": None,
            "providerCost": {
                "used": month_charged,
                "limit": max(total_pool, 0.0),
                "currencyCode": str(billing.get("currency") or "USD"),
                "period": "This month",
            },
            "details": [
                {
                    "title": "Billing",
                    "rows": detail_rows,
                }
            ],
        },
    }
    print(json.dumps([record]))


if __name__ == "__main__":
    main()
