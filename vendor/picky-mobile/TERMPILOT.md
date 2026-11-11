Picky 7.0.0-rc.25, vendored from crates.io. MIT license retained.

The root workspace uses the stable RustCrypto releases already required by russh: aes-gcm 0.11.1, curve25519-dalek 5.0.0, ecdsa 0.17.0, ed25519-dalek 3.0.0, p256/p384/p521/primeorder 0.14.0. Protocol code is unchanged. The standalone desktop RDP workspace retains its original lockfile and dependencies. This patch allows both engines in one native mobile runtime; the mobile verification suite must cover key parsing and RDP authentication.
