//! Independent historical Python vectors exercise production Rust protocol code.
use serde_json::Value;
use termpilot_engine::screen::{
    apple,
    hp::crypto::{Control, Rtp},
};
fn vectors() -> Value {
    serde_json::from_str(include_str!(
        "../../../tests/migration-poc/fixtures/protocol.json"
    ))
    .unwrap()
}
fn bytes(v: &Value) -> Vec<u8> {
    hex::decode(v.as_str().unwrap()).unwrap()
}
#[test]
fn apple_srp_matches_independent_vectors() {
    let cases: Value =
        serde_json::from_str(include_str!("../../../tests/fixtures/srp-rfc5054.json")).unwrap();
    for v in cases.as_array().unwrap() {
        let c = apple::Challenge {
            modulus: bytes(&v["modulus"]),
            generator: 5,
            salt: bytes(&v["salt"]),
            public: bytes(&v["public"]),
            iterations: v["iterations"].as_u64().unwrap() as u32,
            cap: vec![],
        };
        let proof =
            apple::solve(&c, v["password"].as_str().unwrap(), &bytes(&v["entropy"])).unwrap();
        assert_eq!(proof.a, bytes(&v["A"]));
        assert_eq!(proof.m1, bytes(&v["M1"]));
        assert_eq!(proof.key, bytes(&v["K"]));
    }
}
#[test]
fn encrypted_control_matches_independent_stream() {
    let vectors = vectors();
    let v = &vectors["control"];
    let (mut write, mut read) =
        Control::pair(&bytes(&v["key"]).try_into().unwrap(), &bytes(&v["blob"])).unwrap();
    for record in v["records"].as_array().unwrap() {
        let plain = bytes(&record["plaintext"]);
        let wire = bytes(&record["wire"]);
        assert_eq!(write.encrypt(&plain).unwrap(), wire);
        assert_eq!(read.decrypt(&wire[2..]).unwrap(), Some(plain));
    }
}
#[test]
fn srtp_reorder_wrap_and_forgery_match_oracle() {
    let vectors = vectors();
    let packets = vectors["srtp"].as_array().unwrap();
    for v in packets {
        let mut stream = Rtp::new(&bytes(&v["blob"])).unwrap();
        let result = stream.decrypt(&bytes(&v["packet"])).unwrap();
        if v["reject"] == true {
            assert!(result.is_none());
        } else {
            assert_eq!(result.unwrap().payload, bytes(&v["plaintext"]));
            assert!(
                stream.decrypt(&bytes(&v["packet"])).unwrap().is_none(),
                "Replay accepted"
            );
        }
    }
}
#[cfg(target_os = "macos")]
#[test]
fn native_file_frames_at_every_fragment_boundary() {
    use termpilot_engine::screen::hp::files::Wire;
    let packets = vectors()["file_frames"]
        .as_array()
        .unwrap()
        .iter()
        .map(bytes)
        .collect::<Vec<_>>();
    let wire = packets.concat();
    for split in 0..=wire.len() {
        let mut decoder = Wire::default();
        let mut out = decoder.feed(&wire[..split]).unwrap();
        out.extend(decoder.feed(&wire[split..]).unwrap());
        assert_eq!(out, packets);
    }
}

#[test]
fn unapproved_srp_groups_fail_before_secret_arithmetic() {
    for v in vectors()["srp"].as_array().unwrap() {
        let c = apple::Challenge {
            modulus: bytes(&v["modulus"]),
            generator: 5,
            salt: bytes(&v["salt"]),
            public: bytes(&v["public"]),
            iterations: 1,
            cap: vec![],
        };
        assert!(apple::solve(&c, "fixture", &bytes(&v["entropy"])).is_err());
    }
}
