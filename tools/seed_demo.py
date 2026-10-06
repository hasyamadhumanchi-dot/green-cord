#!/usr/bin/env python3
"""Populate a demo database over the live API, exactly as the app would.

Every name below is invented for this demo. No real Princeton HS student appears
anywhere in this repository.

Usage (normally via tools/seed-demo.sh):
    python3 tools/seed_demo.py --base https://127.0.0.1:8443 --cert build/certs/server.crt
"""
import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Obviously synthetic: a first name from the phonetic alphabet, a surname from a
# list of tree species. Nobody is named like this.
COHORT = [
    # (grade, first, last, username, state)
    (9,  "Alpha",   "Alderwood",  "alpha.alderwood",  "empty"),
    (9,  "Bravo",   "Birchfield", "bravo.birchfield", "partway"),
    (9,  "Charlie", "Cedarholm",  "charlie.cedarholm", "pending"),
    (10, "Delta",   "Dogwood",    "delta.dogwood",    "partway"),
    (10, "Echo",    "Elmsworth",  "echo.elmsworth",   "complete"),
    (10, "Foxtrot", "Firbank",    "foxtrot.firbank",  "empty"),
    (11, "Golf",    "Gumtree",    "golf.gumtree",     "pending"),
    (11, "Hotel",   "Hazelmere",  "hotel.hazelmere",  "partway"),
    (11, "India",   "Ironbark",   "india.ironbark",   "complete"),
    (12, "Juliet",  "Junipero",   "juliet.junipero",  "partway"),
    (12, "Kilo",    "Kauripine",  "kilo.kauripine",   "pending"),
    (12, "Lima",    "Larchmont",  "lima.larchmont",   "complete"),
]

ORGANISATIONS = [
    ("Princeton Community Food Pantry", "community"),
    ("Collin County Animal Shelter", "community"),
    ("Princeton Public Library", "community"),
    ("PSHS Campus Beautification Day", "school-based"),
    ("Onion Festival Volunteer Corps", "community"),
    ("Grace Fellowship Clothing Drive", "faith-based"),
    ("Habitat for Humanity Collin County", "community"),
    ("PSHS Peer Tutoring", "school-based"),
]

DESCRIPTIONS = [
    "Sorted and boxed donated food for weekend family distribution.",
    "Walked dogs and cleaned kennels during the Saturday adoption event.",
    "Shelved returns and helped run the children's summer reading hour.",
    "Cleared planting beds and repainted the courtyard benches.",
    "Staffed the information booth and helped with festival setup.",
    "Sorted donated coats and sized them for the winter giveaway.",
    "Framed interior walls on the Elm Street build.",
    "Ran after-school algebra tutoring for freshmen.",
]

PLAN = {
    # state -> list of (hours, org_index, outcome)
    "empty": [],
    "partway": [(6.0, 0, "approved"), (4.5, 3, "approved"), (3.0, 2, "draft")],
    "pending": [(5.0, 1, "approved"), (8.0, 4, "submitted"), (6.5, 5, "submitted")],
    "complete": [(20.0, 0, "approved"), (18.0, 6, "approved"),
                 (15.0, 2, "approved"), (12.0, 4, "approved"),
                 (10.0, 1, "approved"), (9.0, 7, "approved"),
                 (8.0, 5, "approved"), (12.5, 3, "approved"),
                 (6.0, 6, "submitted")],
}

DATES = ["2026-06-14", "2026-06-28", "2026-07-11", "2026-07-25",
         "2026-08-08", "2026-08-22", "2026-09-05", "2026-09-12", "2026-09-19"]


class Client:
    def __init__(self, base, cert):
        self.base = base.rstrip("/")
        self.tls = ssl.create_default_context(cafile=cert)
        self.tls.check_hostname = False

    def call(self, method, path, token=None, payload=None, raw=False):
        data = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method)
        if data:
            request.add_header("Content-Type", "application/json")
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request, context=self.tls, timeout=30) as response:
                body = response.read().decode()
                return body if raw else json.loads(body)
        except urllib.error.HTTPError as exc:
            raise SystemExit(f"{method} {path} -> {exc.code}: {exc.read().decode()}")


# Names for the students who have a code but have not signed up yet. Obviously
# invented, because no real student's name belongs in a demo database.
SPARE_FIRST_NAMES = [
    "Ash", "Briar", "Cedar", "Dune", "Ember", "Fern", "Grove", "Hazel",
    "Iris", "Juniper", "Kestrel", "Linden", "Maple", "Nettle", "Olive", "Pine",
    "Quill", "Rowan", "Sage", "Thorn",
]
SPARE_LAST_NAMES = [
    "Ashford", "Brookvale", "Clearwater", "Dunmore", "Eastgate", "Fairholm",
    "Glenbrook", "Hartwell", "Ironside", "Jessup",
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="https://127.0.0.1:8443")
    parser.add_argument("--cert", default=os.path.join(ROOT, "build", "certs", "server.crt"))
    parser.add_argument("--counselor-username", default="counselor")
    parser.add_argument("--counselor-password", default="counselorpass1")
    parser.add_argument("--spare-codes", type=int, default=40)
    args = parser.parse_args()

    api = Client(args.base, args.cert)
    counselor = api.call("POST", "/auth/login", payload={
        "username": args.counselor_username, "password": args.counselor_password,
    })["token"]
    print(f"signed in as the counselor at {args.base}")

    # A second reviewer, so the demo shows the admin/manager split the
    # counselor asked for rather than describing it.
    manager_code = api.call("POST", "/staff/invites", token=counselor, payload={
        "firstName": "Sam", "lastName": "Okafor", "role": "manager",
    })["code"]
    api.call("POST", "/auth/redeem", payload={
        "code": manager_code, "username": "sam.okafor", "password": "managerpass1",
    })
    print("manager account created: sam.okafor / managerpass1 (Sam Okafor)")

    for grade, first, last, username, state in COHORT:
        # The counselor adds the student by name; the code carries it from
        # there, so redeeming is a confirmation rather than a registration.
        code = api.call("POST", "/invite-codes", token=counselor, payload={
            "students": [{"firstName": first, "lastName": last, "grade": grade}]
        })["codes"][0]["code"]
        session = api.call("POST", "/auth/redeem", payload={
            "code": code, "username": username, "password": "demopassword1",
        })
        token = session["token"]

        created = 0
        for index, (hours, org_index, outcome) in enumerate(PLAN[state]):
            organization, category = ORGANISATIONS[org_index]
            entry = api.call("POST", "/entries", token=token, payload={
                "serviceDate": DATES[index % len(DATES)],
                "hours": hours,
                "category": category,
                "organization": organization,
                "description": DESCRIPTIONS[org_index],
                "verifierName": f"{organization.split()[0]} Volunteer Coordinator",
                "verifierContact": "volunteer.coordinator@example.org",
            })["entry"]
            created += 1
            if outcome == "draft":
                continue
            api.call("POST", f"/entries/{entry['id']}/submit", token=token)
            if outcome == "approved":
                api.call("POST", f"/entries/{entry['id']}/decision", token=counselor,
                         payload={"action": "approve",
                                  "note": "Verification form on file."})

        if state != "empty":
            api.call("PUT", "/checklist/membership-fee", token=token,
                     payload={"checked": True})
            api.call("PUT", "/checklist/google-classroom", token=token,
                     payload={"checked": True})

        progress = api.call("GET", "/progress", token=token)["progress"]
        print(
            f"  grade {grade:<3} {first + ' ' + last:<22} {state:<9} "
            f"{created} entries  verified={progress['verifiedHours']:>6} "
            f"pending={progress['pendingHours']:>5} "
            f"({progress['percentComplete']}% of {progress['thresholdHours']})"
        )

    # Spare codes belong to named students too, so the demo can show the
    # roster listing people who have not signed up yet.
    # Pair the lists so every combination is distinct: cycling both together
    # produced two students called "Ash Ashford", which reads as a bug. Spread
    # them across all four grades too, so the roster filter has something to do.
    spare_students = [
        {
            "firstName": SPARE_FIRST_NAMES[index % len(SPARE_FIRST_NAMES)],
            "lastName": SPARE_LAST_NAMES[
                (index // len(SPARE_FIRST_NAMES)) % len(SPARE_LAST_NAMES)
            ],
            "grade": 9 + (index % 4),
        }
        for index in range(args.spare_codes)
    ]
    distinct = {(s["firstName"], s["lastName"]) for s in spare_students}
    assert len(distinct) == len(spare_students), "spare students must have distinct names"
    spare = api.call("POST", "/invite-codes", token=counselor,
                     payload={"students": spare_students})["codes"]
    print(f"\nissued {len(spare)} unredeemed grade-9 invite codes for the demo")
    for issued in spare[:5]:
        print(f"  {issued['firstName']} {issued['lastName']:<12} {issued['code']}")

    roster = api.call("GET", "/roster", token=counselor)
    print(f"\nroster now shows {roster['count']} students")
    by_grade = {}
    for row in roster["students"]:
        by_grade.setdefault(row["grade"], []).append(row)
    for grade in sorted(by_grade):
        rows = by_grade[grade]
        print(f"  grade {grade}: {len(rows)} students, "
              f"{sum(1 for r in rows if r['percentComplete'] >= 100)} at or over threshold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
