#!/usr/bin/env python3
"""Waits for an uploaded build to finish processing in App Store Connect, then adds it to
every internal TestFlight group so testers get it without anyone clicking in App Store
Connect (an internal group only picks up new builds by itself when it has automatic
distribution turned on).

    asc_distribute.py <bundle id> <build number>

Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file) in the environment, and
PyJWT with cryptography installed.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"


def token():
    with open(os.environ["ASC_KEY_PATH"]) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"})


def call(method, path, body=None, query=None):
    url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        text = r.read()
    return json.loads(text) if text else {}


def main():
    bundle_id, version = sys.argv[1], sys.argv[2]
    apps = call("GET", "/apps", query={"filter[bundleId]": bundle_id})["data"]
    if not apps:
        sys.exit(f"::error::No app in App Store Connect with bundle ID {bundle_id}")
    app_id = apps[0]["id"]

    # Processing usually takes 5-30 minutes; the build may not be listed at all at first.
    deadline = time.time() + 60 * 60
    build = None
    while time.time() < deadline:
        builds = call("GET", "/builds", query={"filter[app]": app_id, "filter[version]": version,
                                               "fields[builds]": "version,processingState"})["data"]
        state = builds[0]["attributes"]["processingState"] if builds else "NOT LISTED YET"
        print(f"Build {version}: {state}", flush=True)
        if state == "VALID":
            build = builds[0]
            break
        if state in ("FAILED", "INVALID"):
            sys.exit(f"::error::App Store Connect rejected build {version} ({state}); check the email Apple sent.")
        time.sleep(30)
    if build is None:
        sys.exit(f"::error::Build {version} was still processing after an hour; add it to the group by hand.")

    groups = call("GET", f"/apps/{app_id}/betaGroups", query={"limit": 200})["data"]
    internal = [g for g in groups if g["attributes"].get("isInternalGroup")]
    if not internal:
        sys.exit("::error::No internal TestFlight group: App Store Connect > TestFlight > Internal Testing > +")
    for g in internal:
        name = g["attributes"]["name"]
        try:
            call("POST", f"/betaGroups/{g['id']}/relationships/builds", body={"data": [{"type": "builds", "id": build["id"]}]})
            print(f"Added build {version} to \"{name}\"")
        except urllib.error.HTTPError as e:
            # A group with access to all builds already has it.
            print(f"::warning::Couldn't add build {version} to \"{name}\": {e.code} {e.read().decode()[:300]}")


if __name__ == "__main__":
    main()
