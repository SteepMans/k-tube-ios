# -*- coding: utf-8 -*-
"""App Store Connect API for the K-Tube release. Nothing secret lives here or is printed.

The key comes from the environment: ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file), or
ASC_ISSUER_FILE with the issuer instead of ASC_ISSUER_ID. Needs `pip install pyjwt[crypto] requests`.

    python Tools/asc.py status                 bundle id, app record, TestFlight groups and the latest builds
    python Tools/asc.py bundle                 register the bundle id ru.steepmans.ktube (the API allows it)
    python Tools/asc.py group "Владелец"       internal group with access to all builds (after the app record exists)
    python Tools/asc.py GET /v1/apps           any call; a body for POST/PATCH is a JSON file as the third argument

The app record itself (POST /v1/apps) is not open to API keys: Apple answers 403, it is created by hand in
App Store Connect, see README.
"""
import json
import os
import pathlib
import sys
import time

import jwt
import requests

BUNDLE_ID = "ru.steepmans.ktube"
NAME = "K-Tube"
HIDE = {"certificateContent", "profileContent", "email", "username", "firstName", "lastName"}


def env(name):
    v = os.environ.get(name, "").strip()
    if not v:
        sys.exit(f"{name} is not set")
    return v


def issuer():
    f = os.environ.get("ASC_ISSUER_FILE", "").strip()
    if f:
        return pathlib.Path(f).read_text(encoding="ascii").strip()
    return env("ASC_ISSUER_ID")


def token():
    now = int(time.time())
    key = pathlib.Path(env("ASC_KEY_PATH")).read_text(encoding="ascii")
    return jwt.encode({"iss": issuer(), "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": env("ASC_KEY_ID"), "typ": "JWT"})


def call(method, path, body=None):
    r = requests.request(method, "https://api.appstoreconnect.apple.com" + path,
                         headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
                         data=json.dumps(body) if body is not None else None, timeout=60)
    try:
        return r.status_code, r.json()
    except ValueError:
        return r.status_code, {"raw": r.text[:300]}


def show(code, d):
    print(code)
    for e in d.get("errors", []):
        print("ERR", e.get("code"), e.get("title"), "|", (e.get("detail") or "")[:300])
    data = d.get("data", [])
    for it in (data if isinstance(data, list) else [data]):
        if not it:
            continue
        a = {k: v for k, v in (it.get("attributes") or {}).items() if k not in HIDE}
        print(" ", it.get("type"), it.get("id"), json.dumps(a, ensure_ascii=False)[:400])


def app_id():
    _, d = call("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}")
    data = d.get("data") or []
    return data[0]["id"] if data else None


def status():
    _, d = call("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE_ID}")
    print("bundle id:", "registered" if d.get("data") else "missing")
    aid = app_id()
    print("app record:", aid or "missing (create it by hand, see README)")
    if not aid:
        return
    _, g = call("GET", f"/v1/apps/{aid}/betaGroups")
    for it in g.get("data", []):
        a = it["attributes"]
        print("group:", a.get("name"), "internal" if a.get("isInternalGroup") else "external",
              "all builds" if a.get("hasAccessToAllBuilds") else "")
    _, b = call("GET", f"/v1/builds?filter[app]={aid}&sort=-uploadedDate&limit=5")
    for it in b.get("data", []):
        a = it["attributes"]
        print("build:", a.get("version"), a.get("processingState"), a.get("uploadedDate"))


def bundle():
    _, d = call("GET", f"/v1/bundleIds?filter[identifier]={BUNDLE_ID}")
    if d.get("data"):
        print("already registered:", d["data"][0]["id"])
        return
    show(*call("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": BUNDLE_ID, "name": NAME, "platform": "IOS"}}}))


def group(name):
    aid = app_id()
    if not aid:
        sys.exit("no app record yet: create K-Tube in App Store Connect first")
    _, g = call("GET", f"/v1/apps/{aid}/betaGroups")
    for it in g.get("data", []):
        if it["attributes"].get("name") == name:
            print("group exists:", it["id"])
            return
    show(*call("POST", "/v1/betaGroups", {"data": {"type": "betaGroups",
        "attributes": {"name": name, "isInternalGroup": True, "hasAccessToAllBuilds": True},
        "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}}))


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    args = sys.argv[1:]
    if not args or args[0] == "status":
        status()
    elif args[0] == "bundle":
        bundle()
    elif args[0] == "group":
        group(args[1] if len(args) > 1 else "Владелец")
    else:
        body = json.loads(pathlib.Path(args[2]).read_text(encoding="utf-8")) if len(args) > 2 else None
        show(*call(args[0], args[1], body))
