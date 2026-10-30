#!/usr/bin/env python3
"""Smoke tests for a deployed ONLYOFFICE Docs release.

Runs from the CI runner against a port-forward of the `documentserver` service.
Stdlib only. Add new checks as functions decorated with @check.

Env:
  DS_URL         base URL of documentserver service   (default http://127.0.0.1:8888)
  JWT_SECRET     jwt.secret used by the release       (default ci-jwt-secret)
  JWT_HEADER     jwt.header                           (default Authorization)
  FIXTURE_URL    in-cluster URL of a test .txt file   (empty = skip conversion test)
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import traceback
import urllib.request
import uuid

DS_URL = os.environ.get("DS_URL", "http://127.0.0.1:8888").rstrip("/")
JWT_SECRET = os.environ.get("JWT_SECRET", "ci-jwt-secret")
JWT_HEADER = os.environ.get("JWT_HEADER", "Authorization")
FIXTURE_URL = os.environ.get("FIXTURE_URL", "")

CHECKS = []


def check(fn):
    CHECKS.append(fn)
    return fn


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jwt_hs256(payload: dict) -> str:
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    body = b64url(json.dumps(payload).encode())
    sig = hmac.new(JWT_SECRET.encode(), f"{header}.{body}".encode(), hashlib.sha256).digest()
    return f"{header}.{body}.{b64url(sig)}"


def http(method, path, payload=None, signed=False, timeout=60):
    url = path if path.startswith("http") else f"{DS_URL}{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if signed:
        # Token in header: the request parameters are wrapped into "payload"
        req.add_header(JWT_HEADER, "Bearer " + jwt_hs256({"payload": payload}))
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


@check
def healthcheck():
    status, body = http("GET", "/healthcheck")
    assert status == 200 and body.strip() == b"true", f"healthcheck: {status} {body[:200]!r}"


@check
def editor_api_js():
    status, body = http("GET", "/web-apps/apps/api/documents/api.js")
    assert status == 200 and b"DocsAPI" in body, f"api.js: {status}, {len(body)} bytes"


@check
def command_service_version():
    payload = {"c": "version"}
    status, body = http("POST", "/coauthoring/CommandService.ashx", payload, signed=True)
    data = json.loads(body)
    assert data.get("error") == 0, f"CommandService answered {data}"
    print(f"    Docs version: {data.get('version')}")


@check
def conversion_txt_to_pdf():
    if not FIXTURE_URL:
        print("    skipped: FIXTURE_URL is not set")
        return
    payload = {
        "async": False,
        "filetype": "txt",
        "outputtype": "pdf",
        "key": uuid.uuid4().hex,
        "title": "smoke.txt",
        "url": FIXTURE_URL,
    }
    status, body = http("POST", "/ConvertService.ashx", payload, signed=True, timeout=180)
    data = json.loads(body)
    assert data.get("endConvert") and data.get("fileUrl"), f"ConvertService answered {data}"
    _, pdf = http("GET", data["fileUrl"])
    assert pdf.startswith(b"%PDF"), f"result is not a PDF ({len(pdf)} bytes)"
    print(f"    converted, {len(pdf)} bytes")


def main():
    failed = []
    for fn in CHECKS:
        name = fn.__name__
        started = time.monotonic()
        try:
            fn()
            print(f"PASS {name} ({time.monotonic() - started:.1f}s)")
        except Exception:  # noqa: BLE001 - report every failure, keep going
            failed.append(name)
            print(f"FAIL {name}")
            traceback.print_exc()
    print(f"\n{len(CHECKS) - len(failed)}/{len(CHECKS)} smoke checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
