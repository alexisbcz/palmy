"""Write sample.1pux: a 1Password export with fake data, in the layout
1Password 8 produces (export.attributes + export.data in a zip, deflated),
as documented by Bitwarden's importer types
(libs/importer/src/importers/onepassword/types/onepassword-1pux-importer-types.ts).
Run: python3 -I make-1pux.py <dir>"""
import json, sys, zipfile, os

data = {
  "accounts": [{
    "attrs": {"accountName": "Fixture", "name": "Fixture Person", "email": "fixture@example.org", "uuid": "FIXTUREACCOUNT", "domain": "https://my.1password.com/"},
    "vaults": [{
      "attrs": {"uuid": "fixturevault", "desc": "", "avatar": "", "name": "Private", "type": "P"},
      "items": [
        {
          "uuid": "op-login-1", "favIndex": 1, "createdAt": 1700000000, "updatedAt": 1710000000,
          "state": "active", "categoryUuid": "001",
          "details": {
            "loginFields": [
              {"value": "fixture-op-user", "id": "", "name": "username", "fieldType": "T", "designation": "username"},
              {"value": "op-fixture-pass-1", "id": "", "name": "password", "fieldType": "P", "designation": "password"}
            ],
            "notesPlain": "A 1Password fixture.",
            "sections": [{
              "title": "Extra", "name": "extra",
              "fields": [
                {"title": "one-time password", "id": "totp1", "value": {"totp": "otpauth://totp/op?secret=JBSWY3DPEHPK3PXP"}},
                {"title": "Security answer", "id": "sa", "value": {"concealed": "op-fixture-answer"}},
                {"title": "Member since", "id": "ms", "value": {"string": "2019"}}
              ]
            }],
            "passwordHistory": [{"value": "op-fixture-old-pass", "time": 1690000000}]
          },
          "overview": {
            "subtitle": "fixture-op-user", "title": "Example Cloud",
            "url": "https://cloud.example.com",
            "urls": [{"label": "", "url": "https://cloud.example.com"}, {"label": "console", "url": "https://console.example.com"}],
            "tags": ["cloud", "fixture"], "ps": 80
          }
        },
        {
          "uuid": "op-card-1", "favIndex": 0, "createdAt": 1700000000, "updatedAt": 1700000000,
          "state": "active", "categoryUuid": "002",
          "details": {"loginFields": [], "notesPlain": "", "sections": [{
            "title": "", "name": "",
            "fields": [
              {"title": "cardholder name", "id": "cardholder", "value": {"string": "Fixture Person"}},
              {"title": "number", "id": "ccnum", "value": {"creditCardNumber": "4111111111111111"}},
              {"title": "verification number", "id": "cvv", "value": {"concealed": "123"}},
              {"title": "expiry date", "id": "expiry", "value": {"monthYear": 203012}}
            ]}], "passwordHistory": []},
          "overview": {"subtitle": "", "title": "Example Debit Card", "url": "", "tags": [], "ps": 0}
        },
        {
          "uuid": "op-archived", "favIndex": 0, "createdAt": 1700000000, "updatedAt": 1700000000,
          "state": "archived", "categoryUuid": "001",
          "details": {"loginFields": [], "notesPlain": "", "sections": [], "passwordHistory": []},
          "overview": {"title": "Archived thing", "url": "", "tags": []}
        }
      ]
    }]
  }]
}

out = os.path.join(sys.argv[1], "sample.1pux")
with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("export.attributes", json.dumps({"version": 3, "description": "1Password Unencrypted Export", "createdAt": 1710000000}))
    z.writestr("export.data", json.dumps(data, indent=2))
    z.writestr("files/", "")
print(out)
