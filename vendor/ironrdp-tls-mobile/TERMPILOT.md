# TermPilot mobile TLS adapter

Copied from IronRDP 38b074e4befeed6dd25a67decf3558bb9e7762f9, crate ironrdp-tls 0.2.2. MIT OR Apache-2.0 licenses are included.

Only mobile trust-root loading changes: iOS and Android use the webpki-roots Mozilla trust store, because rustls-native-certs probes Unix files that do not exist in their sandboxes. Strict hostname/chain/signature checks and the existing explicit leaf-certificate callback remain enabled. Desktop targets continue using their platform root stores. Private enterprise certificates use the per-endpoint certificate prompt/pin; no trust-all fallback is introduced.
