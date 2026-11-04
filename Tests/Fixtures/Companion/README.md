# Companion fixtures

| File | What it is |
|---|---|
| `print-package.lppkg` | The package of `PrintPackageTests.Make_WritesTheGoldenFile`, written by the C# tests (`LAZYPRINT_WRITE_GOLDEN=1`) and read back by the Swift ones |
| `tls-desktop-a.p12` | The desktop identity of `CompanionLoopbackTests` and `CompanionHostTests`: a self-signed P-256 certificate (CN "Test Desktop a Lazy Print") and its private key. The SHA-256 of its SubjectPublicKeyInfo is `9c42a3956a1a30612c1e2290b21c7a99ed3b2560e90c5416da675e6600bbf0e9` |
| `tls-desktop-b.p12` | The same for the identity after Reset pairing (CN "Test Desktop b Lazy Print"), so the key changes. The SHA-256 of its SubjectPublicKeyInfo is `b2b2c0802ae33febc2877d630ed144853d6da2de56cf0df765e0e21c49b54ce6` |

The loopback server serves the identities imported to memory, because a CI runner's keychain refuses the keys a
test would make (errSecMissingEntitlement). Test fixtures only: no app ships a key. Both files are PKCS #12 with
3DES and a SHA-1 MAC so every Apple system imports them; the password is in `CompanionFixtures.loopbackPassword`,
and `CompanionLoopbackTests.testTheFixtureIdentitiesHaveTheirFingerprints` checks the two fingerprints. They were
made once with OpenSSL, for `a` and `b`:

```
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 7300 -sha256 \
    -subj "/CN=Test Desktop a Lazy Print" -keyout key.pem -out cert.pem
openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -name desktop-a -inkey key.pem -in cert.pem -out tls-desktop-a.p12
```

The files are kept byte for byte (`../../.gitattributes` turns off line-ending conversion).
