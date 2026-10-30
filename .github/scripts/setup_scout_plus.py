"""Creates the Scout Plus subscription in App Store Connect, so the app can sell it with Apple's own
payment sheet (and TestFlight testers can buy it in the sandbox, where nothing is charged).

Safe to run again: anything that already exists is left as it is.

  - a subscription group "Scout Plus" on the app com.ralphgeb.scout
  - one auto-renewing monthly subscription, com.ralphgeb.scout.plus.monthly
  - names in English (US and UK)
  - on sale everywhere, at $0.99 in the US and £0.99 in the UK, and Apple's equivalent elsewhere

Apple also needs the Paid Applications Agreement signed (App Store Connect > Business) before
any purchase works, even in the sandbox; this script can't do that part.
"""
import os
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.ralphgeb.scout"
PRODUCT_ID = "com.ralphgeb.scout.plus.monthly"
GROUP_NAME = "Scout Plus"
PRICE = "0.99"


def token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"].strip(), "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        os.environ["ASC_PRIVATE_KEY"],
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"].strip(), "typ": "JWT"},
    )


S = requests.Session()
S.headers.update({"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})


def get(path, **params):
    r = S.get(f"{API}{path}", params=params, timeout=60)
    if r.status_code != 200:
        raise SystemExit(f"::error::GET {path} answered {r.status_code}: {r.text[:400]}")
    return r.json()


def post(path, body, ok_conflict=False):
    r = S.post(f"{API}{path}", json={"data": body}, timeout=60)
    if r.status_code in (200, 201):
        return r.json()["data"]
    if ok_conflict and r.status_code == 409:
        return None
    raise SystemExit(f"::error::POST {path} answered {r.status_code}: {r.text[:600]}")


def rel(kind, ident):
    return {"data": {"type": kind, "id": ident}}


def main() -> int:
    apps = get("/apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
    if not apps:
        raise SystemExit(f"::error::No app with bundle ID {BUNDLE_ID} in App Store Connect")
    app = apps[0]["id"]
    print(f"App: {apps[0]['attributes'].get('name')} ({app})")

    groups = get(f"/apps/{app}/subscriptionGroups", limit=50)["data"]
    group = next((g["id"] for g in groups if g["attributes"].get("referenceName") == GROUP_NAME), None)
    if not group:
        group = post("/subscriptionGroups", {"type": "subscriptionGroups", "attributes": {"referenceName": GROUP_NAME},
                                             "relationships": {"app": rel("apps", app)}})["id"]
        print("Created the subscription group")
    have = {l["attributes"]["locale"] for l in get(f"/subscriptionGroups/{group}/subscriptionGroupLocalizations")["data"]}
    for locale in ("en-US", "en-GB"):
        if locale not in have:
            post("/subscriptionGroupLocalizations", {"type": "subscriptionGroupLocalizations",
                 "attributes": {"name": "Scout Plus", "locale": locale},
                 "relationships": {"subscriptionGroup": rel("subscriptionGroups", group)}}, ok_conflict=True)

    subs = get(f"/subscriptionGroups/{group}/subscriptions", limit=50)["data"]
    sub = next((s for s in subs if s["attributes"].get("productId") == PRODUCT_ID), None)
    if not sub:
        sub = post("/subscriptions", {"type": "subscriptions", "attributes": {
            "name": "Scout Plus Monthly", "productId": PRODUCT_ID, "subscriptionPeriod": "ONE_MONTH",
            "familySharable": False, "groupLevel": 1,
            "reviewNote": "Unlocks every story, following stocks, custom colours and app icons."},
            "relationships": {"group": rel("subscriptionGroups", group)}})
        print("Created the monthly subscription")
    sid = sub["id"]

    have = {l["attributes"]["locale"] for l in get(f"/subscriptions/{sid}/subscriptionLocalizations")["data"]}
    for locale in ("en-US", "en-GB"):
        if locale not in have:
            post("/subscriptionLocalizations", {"type": "subscriptionLocalizations", "attributes": {
                "locale": locale, "name": "Scout Plus",
                "description": "Every story, your stocks, your colours and icons."},
                "relationships": {"subscription": rel("subscriptions", sid)}}, ok_conflict=True)

    # on sale everywhere
    territories = [t["id"] for t in get("/territories", limit=200)["data"]]
    r = S.get(f"{API}/subscriptions/{sid}/subscriptionAvailability", timeout=60)
    if r.status_code != 200 or not r.json().get("data"):
        post("/subscriptionAvailabilities", {"type": "subscriptionAvailabilities",
             "attributes": {"availableInNewTerritories": True},
             "relationships": {"subscription": rel("subscriptions", sid),
                               "availableTerritories": {"data": [{"type": "territories", "id": t} for t in territories]}}},
             ok_conflict=True)
        print(f"On sale in {len(territories)} territories")

    # prices: 0.99 in the US and UK, Apple's equivalents elsewhere
    priced = {p["relationships"]["territory"]["data"]["id"]
              for p in get(f"/subscriptions/{sid}/prices", limit=200, include="territory")["data"]
              if p.get("relationships", {}).get("territory", {}).get("data")}

    def point(territory):
        pts = get(f"/subscriptions/{sid}/pricePoints", **{"filter[territory]": territory, "limit": 200})["data"]
        return next((p["id"] for p in pts if p["attributes"].get("customerPrice") == PRICE), None)

    def set_price(territory, pp):
        post("/subscriptionPrices", {"type": "subscriptionPrices", "attributes": {"preserveCurrentPrice": False},
             "relationships": {"subscription": rel("subscriptions", sid),
                               "subscriptionPricePoint": rel("subscriptionPricePoints", pp),
                               "territory": rel("territories", territory)}}, ok_conflict=True)

    usa = point("USA")
    if not usa:
        raise SystemExit(f"::error::No {PRICE} price point in the US")
    if "USA" not in priced:
        set_price("USA", usa)
    gbr = point("GBR")
    if gbr and "GBR" not in priced:
        set_price("GBR", gbr)
    done = 0
    for eq in get(f"/subscriptionPricePoints/{usa}/equalizations", limit=200, include="territory")["data"]:
        t = eq.get("relationships", {}).get("territory", {}).get("data", {}).get("id")
        if t and t not in priced and t not in ("USA", "GBR"):
            set_price(t, eq["id"])
            done += 1
    print(f"Prices: USA and GBR at {PRICE}, plus {done} other territories")

    state = get(f"/subscriptions/{sid}")["data"]["attributes"].get("state")
    print(f"::notice::Scout Plus Monthly ({PRODUCT_ID}) is set up; its state is {state}. "
          "TestFlight testers can buy it in the sandbox (no charge) once the Paid Applications Agreement is signed "
          "in App Store Connect > Business.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
