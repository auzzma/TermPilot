//! RFC 7616 challenge responses, used only over the transport's validated HTTPS URL.
use super::{err, Result};
use sha2::Digest;
use std::collections::BTreeMap;

fn parameters(input: &str) -> Result<BTreeMap<String, String>> {
    let mut rest = input.trim();
    if !rest
        .get(..7)
        .is_some_and(|s| s.eq_ignore_ascii_case("digest "))
    {
        return Err(err("syncDigest", "服务器未提供 Digest 认证。"));
    }
    rest = &rest[7..];
    let mut values = BTreeMap::new();
    while !rest.trim_matches([' ', ',']).is_empty() {
        rest = rest.trim_start_matches([' ', ',']);
        let (key, tail) = rest
            .split_once('=')
            .ok_or_else(|| err("syncDigest", "Digest 认证响应无效。"))?;
        let key = key.trim().to_ascii_lowercase();
        rest = tail.trim_start();
        let value = if rest.starts_with('"') {
            let mut text = String::new();
            let mut escaped = false;
            let mut end = None;
            for (i, c) in rest[1..].char_indices() {
                if escaped {
                    text.push(c);
                    escaped = false;
                } else if c == '\\' {
                    escaped = true;
                } else if c == '"' {
                    end = Some(i + 2);
                    break;
                } else {
                    text.push(c);
                }
            }
            rest = &rest[end.ok_or_else(|| err("syncDigest", "Digest 引号未闭合。"))?..];
            text
        } else {
            let end = rest.find(',').unwrap_or(rest.len());
            let text = rest[..end].trim().to_owned();
            rest = &rest[end..];
            text
        };
        if key.is_empty() || values.insert(key, value).is_some() {
            return Err(err("syncDigest", "Digest 字段重复。"));
        }
    }
    Ok(values)
}
fn quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}
pub(super) fn authorization(
    challenge: &str,
    username: &str,
    password: &str,
    method: &str,
    uri: &str,
    body: &[u8],
    cnonce: &str,
) -> Result<String> {
    let p = parameters(challenge)?;
    let field = |name: &str| p.get(name).map(String::as_str).unwrap_or("");
    let realm = field("realm");
    let nonce = field("nonce");
    if nonce.is_empty() {
        return Err(err("syncDigest", "Digest 缺少随机数。"));
    }
    let algorithm = if field("algorithm").is_empty() {
        "MD5"
    } else {
        field("algorithm")
    };
    let base = algorithm.to_ascii_uppercase();
    let base = base.trim_end_matches("-SESS");
    if !matches!(base, "MD5" | "SHA-256" | "SHA-512-256") {
        return Err(err("syncDigest", "不支持服务器的 Digest 算法。"));
    }
    let h = |v: &[u8]| match base {
        "MD5" => hex::encode(md5::Md5::digest(v)),
        "SHA-256" => hex::encode(sha2::Sha256::digest(v)),
        _ => hex::encode(sha2::Sha512_256::digest(v)),
    };
    let qops = field("qop").split(',').map(str::trim).collect::<Vec<_>>();
    let qop = if qops.contains(&"auth") {
        "auth"
    } else if qops.contains(&"auth-int") {
        "auth-int"
    } else if field("qop").is_empty() {
        ""
    } else {
        return Err(err("syncDigest", "不支持服务器的 Digest 保护模式。"));
    };
    let mut a1 = zeroize::Zeroizing::new(h(format!("{username}:{realm}:{password}").as_bytes()));
    if algorithm.to_ascii_lowercase().ends_with("-sess") {
        *a1 = h(format!("{}:{nonce}:{cnonce}", a1.as_str()).as_bytes());
    }
    let a2 = if qop == "auth-int" {
        h(format!("{method}:{uri}:{}", h(body)).as_bytes())
    } else {
        h(format!("{method}:{uri}").as_bytes())
    };
    let response = if qop.is_empty() {
        h(format!("{}:{nonce}:{a2}", a1.as_str()).as_bytes())
    } else {
        h(format!("{}:{nonce}:00000001:{cnonce}:{qop}:{a2}", a1.as_str()).as_bytes())
    };
    let user = if field("userhash") == "true" {
        h(format!("{username}:{realm}").as_bytes())
    } else {
        username.into()
    };
    let mut parts = vec![
        format!("username={}", quote(&user)),
        format!("realm={}", quote(realm)),
        format!("nonce={}", quote(nonce)),
        format!("uri={}", quote(uri)),
        format!("response={}", quote(&response)),
        format!("algorithm={algorithm}"),
    ];
    if !qop.is_empty() {
        parts.extend([
            format!("qop={qop}"),
            "nc=00000001".into(),
            format!("cnonce={}", quote(cnonce)),
        ]);
    } else if algorithm.to_ascii_lowercase().ends_with("-sess") {
        parts.push(format!("cnonce={}", quote(cnonce)));
    }
    if p.contains_key("opaque") {
        parts.push(format!("opaque={}", quote(field("opaque"))));
    }
    if field("userhash") == "true" {
        parts.push("userhash=true".into());
    }
    Ok(format!("Digest {}", parts.join(", ")))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rfc7616_sha256_vector_and_rejected_challenges() {
        let challenge="Digest realm=\"http-auth@example.org\", qop=\"auth, auth-int\", algorithm=SHA-256, nonce=\"7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v\", opaque=\"example,opaque\"";
        let value = authorization(
            challenge,
            "Mufasa",
            "Circle of Life",
            "GET",
            "/dir/index.html",
            b"",
            "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ",
        )
        .unwrap();
        assert!(value.contains("753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1"));
        assert!(value.contains("opaque=\"example,opaque\""));
        assert!(authorization(
            "Digest nonce=\"a\",nonce=\"b\"",
            "x",
            "y",
            "GET",
            "/",
            b"",
            "z"
        )
        .is_err());
        assert!(authorization(
            "Digest nonce=\"a\",algorithm=unknown",
            "x",
            "y",
            "GET",
            "/",
            b"",
            "z"
        )
        .is_err());
        let md5=authorization("Digest realm=\"testrealm@host.com\",qop=\"auth\",nonce=\"dcd98b7102dd2f0e8b11d0f600bfb0c093\"","Mufasa","Circle Of Life","GET","/dir/index.html",b"","0a4f113b").unwrap();
        assert!(md5.contains("6629fae49393a05397450978507c4ef1"));
    }
}
