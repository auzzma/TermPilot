//! Native WebDAV and S3-compatible object storage adapters.
//! Independent immutable objects avoid shared-file last-writer-wins races.
use super::{err, Result};
use hmac::{Hmac, Mac};
use reqwest::{
    blocking::{Client, RequestBuilder, Response},
    Method, Url,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    path::PathBuf,
    time::Duration,
};

const LIMIT: usize = 8 * 1024 * 1024;
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Provider {
    Webdav {
        endpoint: String,
        username: String,
        password: String,
        #[serde(default)]
        auth_type: String,
        #[serde(default)]
        token: String,
    },
    S3 {
        endpoint: String,
        bucket: String,
        region: String,
        access_key: String,
        secret_key: String,
        #[serde(default)]
        session_token: String,
        #[serde(default)]
        prefix: String,
    },
    /// Cloudflare R2 uses S3 Signature V4 with the fixed `auto` region.
    R2 {
        endpoint: String,
        bucket: String,
        access_key: String,
        secret_key: String,
        #[serde(default)]
        prefix: String,
    },
    // Local directory is useful for offline acceptance and user-managed mounted cloud folders.
    Folder {
        path: PathBuf,
    },
    /// Keep local journals readable after a provider is removed. No transport exists.
    #[serde(other)]
    Unavailable,
}
impl Provider {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Webdav { .. } => "WebDAV",
            Self::S3 { .. } => "S3",
            Self::R2 { .. } => "Cloudflare R2",
            Self::Unavailable => "已停止支持的服务",
            Self::Folder { .. } => "本地验证目录",
        }
    }
    pub fn public(&self) -> Value {
        match self {
            Self::Webdav {
                endpoint,
                username,
                auth_type,
                ..
            } => {
                json!({"kind":"webdav","endpoint":endpoint,"username":username,"auth_type":auth_type})
            }
            Self::S3 {
                endpoint,
                bucket,
                region,
                prefix,
                ..
            } => {
                json!({"kind":"s3","endpoint":endpoint,"bucket":bucket,"region":region,"prefix":prefix})
            }
            Self::R2 {
                endpoint,
                bucket,
                prefix,
                ..
            } => {
                json!({"kind":"r2","endpoint":endpoint,"bucket":bucket,"prefix":prefix})
            }
            Self::Unavailable => json!({"kind":"unavailable"}),
            Self::Folder { path } => json!({"kind":"folder","path":path}),
        }
    }
}
pub trait Objects {
    fn list(&mut self) -> Result<Vec<String>>;
    fn get(&mut self, name: &str) -> Result<Option<Vec<u8>>>;
    fn put(&mut self, name: &str, data: &[u8]) -> Result<()>;
    fn server_time(&self) -> Option<i64>;
    /// Atomically replace a small control object only if its exact previous bytes
    /// still match. Unsupported providers must fail closed, never emulate CAS.
    fn check_conditionals(&mut self, _library: &str) -> Result<()> {
        Ok(())
    }
    fn compare_exchange(
        &mut self,
        _name: &str,
        _expected: Option<&[u8]>,
        _data: &[u8],
    ) -> Result<bool> {
        Err(err(
            "syncConditionalWrite",
            "云服务不支持安全的条件写入，不能修改同步 Key。",
        ))
    }
}
pub struct Backend {
    provider: Provider,
    client: Client,
    prefix: String,
    ids: BTreeMap<String, String>,
    clock: Option<i64>,
}
fn network(_: reqwest::Error) -> super::CoreError {
    err(
        "syncNetwork",
        "云服务请求失败；本机修改已保留，可稍后重试。",
    )
}
fn valid_name(name: &str) -> Result<()> {
    if name.len() > 220
        || name.is_empty()
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.' || b == b'_')
    {
        Err(err("syncObject", "同步对象名称无效。"))
    } else {
        Ok(())
    }
}
fn endpoint(value: &str) -> Result<Url> {
    let url = Url::parse(value).map_err(|_| err("syncURL", "云服务地址无效。"))?;
    if url.scheme() != "https"
        && !(url.scheme() == "http"
            && matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]")))
    {
        return Err(err("syncTLS", "云服务地址需要使用 HTTPS。"));
    }
    if !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(err("syncURL", "请分别填写云地址和认证信息。"));
    }
    Ok(url)
}
fn validate_r2_endpoint(value: &str) -> Result<()> {
    let url = endpoint(value)?;
    let host = url.host_str().unwrap_or("");
    let valid_host = host
        .strip_suffix(".r2.cloudflarestorage.com")
        .is_some_and(|prefix| {
            let parts: Vec<_> = prefix.split('.').collect();
            (parts.len() == 1 || parts.len() == 2)
                && parts[0].len() == 32
                && parts[0].bytes().all(|c| c.is_ascii_hexdigit())
                && parts.iter().skip(1).all(|part| {
                    !part.is_empty()
                        && part
                            .bytes()
                            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
                })
        });
    if url.scheme() != "https"
        || !valid_host
        || url.port().is_some()
        || !matches!(url.path(), "" | "/")
    {
        return Err(err(
            "syncR2Endpoint",
            "请填写 R2 控制台的 HTTPS S3 API 地址，不含存储桶路径；不能使用 r2.dev 或公开域名。",
        ));
    }
    Ok(())
}
impl Backend {
    pub fn new(provider: Provider, library: &str) -> Result<Self> {
        uuid::Uuid::parse_str(library).map_err(|_| err("syncLibrary", "同步库 ID 无效。"))?;
        match &provider {
            Provider::Webdav { endpoint: e, .. } | Provider::S3 { endpoint: e, .. } => {
                endpoint(e)?;
            }
            Provider::Folder { path } => {
                if !path.is_absolute() {
                    return Err(err("syncPath", "测试目录必须是绝对路径。"));
                }
                std::fs::create_dir_all(path).map_err(|_| err("syncIO", "无法创建同步目录。"))?;
            }
            Provider::R2 { endpoint: value, bucket, access_key, secret_key, .. } => {
                validate_r2_endpoint(value)?;
                if !(3..=63).contains(&bucket.len())
                    || !bucket.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
                    || bucket.starts_with('-') || bucket.ends_with('-') {
                    return Err(err("syncR2", "R2 存储桶名称需为 3–63 个小写字母、数字或连字符。"));
                }
                if access_key.trim().is_empty() || secret_key.trim().is_empty() {
                    return Err(err("syncAuth", "请填写 R2 Access Key ID 和 Secret Access Key。"));
                }
            }
            Provider::Unavailable => return Err(err("syncProviderUnavailable", "原同步服务已停止支持，请在同步设置中更换为 WebDAV、S3 或 Cloudflare R2。本机数据已保留。")),
        }
        if let Provider::Webdav { auth_type, .. } = &provider {
            if !matches!(auth_type.as_str(), "" | "basic" | "digest" | "token") {
                return Err(err("syncAuth", "请选择 Basic、Digest 或 Token 认证。"));
            }
        }
        let client = Client::builder()
            .timeout(Duration::from_secs(45))
            .connect_timeout(Duration::from_secs(12))
            .redirect(reqwest::redirect::Policy::none())
            .user_agent("TermPilot/0.2 sync/1")
            .build()
            .map_err(network)?;
        Ok(Self {
            provider,
            client,
            prefix: format!("tp1-{library}-"),
            ids: BTreeMap::new(),
            clock: None,
        })
    }
    fn send(&self, request: RequestBuilder) -> Result<Response> {
        let original = request.try_clone();
        let mut response = request.send().map_err(network)?;
        if response.status().as_u16() == 401 {
            if let Provider::Webdav {
                auth_type,
                username,
                password,
                ..
            } = &self.provider
            {
                if auth_type == "digest" {
                    let retry = original
                        .ok_or_else(|| err("syncDigest", "认证请求无法重试。"))?
                        .build()
                        .map_err(network)?;
                    let uri = format!(
                        "{}{}",
                        retry.url().path(),
                        retry
                            .url()
                            .query()
                            .map(|q| format!("?{q}"))
                            .unwrap_or_default()
                    );
                    let auth = response
                        .headers()
                        .get_all("www-authenticate")
                        .iter()
                        .filter_map(|h| h.to_str().ok())
                        .find_map(|challenge| {
                            super::digest_auth::authorization(
                                challenge,
                                username,
                                password,
                                retry.method().as_str(),
                                &uri,
                                retry.body().and_then(|b| b.as_bytes()).unwrap_or_default(),
                                &uuid::Uuid::new_v4().to_string(),
                            )
                            .ok()
                        })
                        .ok_or_else(|| {
                            err("syncDigest", "服务器没有返回可用的 Digest 认证方式。")
                        })?;
                    let mut retry = retry;
                    retry.headers_mut().insert(
                        "authorization",
                        auth.parse()
                            .map_err(|_| err("syncDigest", "Digest 认证字段无效。"))?,
                    );
                    response = self.client.execute(retry).map_err(network)?;
                }
            }
        }
        Ok(response)
    }
    fn read(&mut self, request: RequestBuilder) -> Result<(u16, Vec<u8>)> {
        let mut response = self.send(request)?;
        let status = response.status().as_u16();
        if status == 401 || status == 403 {
            return Err(err("syncAuth", "云端授权失效或权限不足，请重新授权。"));
        }
        if status == 429 {
            return Err(err("syncRateLimit", "云服务限流，请稍后重试。"));
        }
        if let Some(date) = response
            .headers()
            .get("date")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| chrono::DateTime::parse_from_rfc2822(s).ok())
        {
            self.clock = Some(date.timestamp());
        }
        if response.content_length().unwrap_or(0) > LIMIT as u64 {
            return Err(err("syncSize", "云端对象超过允许大小。"));
        }
        let mut bytes = Vec::new();
        (&mut response)
            .take((LIMIT + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| err("syncNetwork", "云端响应未完整接收。"))?;
        if bytes.len() > LIMIT {
            return Err(err("syncSize", "云端对象超过允许大小。"));
        }
        Ok((status, bytes))
    }
    fn webdav_url(&self, name: &str) -> String {
        let Provider::Webdav { endpoint, .. } = &self.provider else {
            unreachable!()
        };
        format!("{}/{}", endpoint.trim_end_matches('/'), name)
    }
    fn webdav(&self, method: Method, name: &str) -> RequestBuilder {
        let Provider::Webdav {
            username,
            password,
            auth_type,
            token,
            ..
        } = &self.provider
        else {
            unreachable!()
        };
        let request = self.client.request(method, self.webdav_url(name));
        match auth_type.as_str() {
            "token" => request.bearer_auth(token),
            "digest" => request,
            _ => request.basic_auth(username, Some(password)),
        }
    }
    fn s3(
        &self,
        method: Method,
        name: &str,
        query: &[(String, String)],
        body: &[u8],
    ) -> Result<RequestBuilder> {
        let (endpoint, bucket, region, access_key, secret_key, session_token, prefix) =
            match &self.provider {
                Provider::S3 {
                    endpoint,
                    bucket,
                    region,
                    access_key,
                    secret_key,
                    session_token,
                    prefix,
                } => (
                    endpoint,
                    bucket,
                    region.as_str(),
                    access_key,
                    secret_key,
                    session_token.as_str(),
                    prefix,
                ),
                Provider::R2 {
                    endpoint,
                    bucket,
                    access_key,
                    secret_key,
                    prefix,
                } => (endpoint, bucket, "auto", access_key, secret_key, "", prefix),
                _ => unreachable!(),
            };
        if bucket.is_empty() || bucket.contains('/') || region.is_empty() {
            return Err(err("syncS3", "请填写有效存储桶和区域。"));
        }
        let path = if query.iter().any(|(key, _)| key == "list-type") {
            encode_path(bucket)
        } else {
            [bucket.as_str(), prefix.trim_matches('/'), name]
                .into_iter()
                .filter(|v| !v.is_empty())
                .map(encode_path)
                .collect::<Vec<_>>()
                .join("/")
        };
        let url = format!("{}/{path}", endpoint.trim_end_matches('/'));
        let parsed = Url::parse(&url).map_err(|_| err("syncS3", "S3 地址无效。"))?;
        let host = match parsed.port() {
            Some(port) => format!("{}:{port}", parsed.host_str().unwrap_or("")),
            None => parsed.host_str().unwrap_or("").into(),
        };
        let time = chrono::Utc::now();
        let date = time.format("%Y%m%d").to_string();
        let timestamp = time.format("%Y%m%dT%H%M%SZ").to_string();
        let digest = hex::encode(Sha256::digest(body));
        let mut headers = BTreeMap::from([
            ("host", host.clone()),
            ("x-amz-content-sha256", digest.clone()),
            ("x-amz-date", timestamp.clone()),
        ]);
        if !session_token.is_empty() {
            headers.insert("x-amz-security-token", session_token.to_owned());
        }
        let signed = headers.keys().copied().collect::<Vec<_>>().join(";");
        let canonical_headers = headers
            .iter()
            .map(|(k, v)| format!("{k}:{}\n", v.trim()))
            .collect::<String>();
        let mut query = query
            .iter()
            .map(|(k, v)| (encode(k), encode(v)))
            .collect::<Vec<_>>();
        query.sort();
        let query = query
            .into_iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("&");
        let canonical = format!(
            "{}\n{}\n{}\n{}\n{}\n{}",
            method.as_str(),
            parsed.path(),
            query,
            canonical_headers,
            signed,
            digest
        );
        let scope = format!("{date}/{region}/s3/aws4_request");
        let string = format!(
            "AWS4-HMAC-SHA256\n{timestamp}\n{scope}\n{}",
            hex::encode(Sha256::digest(canonical.as_bytes()))
        );
        let signing = hmac(
            &hmac(
                &hmac(
                    &hmac(format!("AWS4{secret_key}").as_bytes(), date.as_bytes()),
                    region.as_bytes(),
                ),
                b"s3",
            ),
            b"aws4_request",
        );
        let signature = hex::encode(hmac(&signing, string.as_bytes()));
        let mut request=self.client.request(method,if query.is_empty(){url}else{format!("{url}?{query}")})
            .header("authorization",format!("AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed}, Signature={signature}"));
        for (k, v) in headers {
            request = request.header(k, v);
        }
        Ok(request.body(body.to_vec()))
    }
    fn verify(&mut self, name: &str, data: &[u8]) -> Result<()> {
        if self.get(name)?.as_deref() != Some(data) {
            return Err(err(
                "syncVerify",
                "云端重新读取校验失败，本机待上传内容已保留。",
            ));
        }
        Ok(())
    }
}
impl Objects for Backend {
    fn list(&mut self) -> Result<Vec<String>> {
        self.ids.clear();
        let mut pages = 0usize;
        match self.provider.clone() {
            Provider::Folder { path } => {
                for entry in
                    std::fs::read_dir(path).map_err(|_| err("syncIO", "无法读取同步目录。"))?
                {
                    let entry = entry.map_err(|_| err("syncIO", "无法读取同步目录。"))?;
                    let name = entry.file_name().to_string_lossy().into_owned();
                    if name.starts_with(&self.prefix)
                        && entry.file_type().is_ok_and(|t| t.is_file())
                    {
                        self.ids.insert(name.clone(), name);
                    }
                }
            }
            Provider::Webdav { .. } => {
                let request=self.webdav(Method::from_bytes(b"PROPFIND").unwrap(),"").header("depth","1").header("content-type","application/xml")
                    .body("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>");
                let (status, bytes) = self.read(request)?;
                if status != 207 && status != 200 {
                    return Err(err("syncWebDAV", "WebDAV 目录查询失败，请检查地址和权限。"));
                }
                for href in xml_values(&bytes, b"href")? {
                    let url = Url::parse(&self.webdav_url(""))
                        .unwrap()
                        .join(&href)
                        .map_err(|_| err("syncResponse", "WebDAV 路径无效。"))?;
                    let name = url.path().rsplit('/').next().unwrap_or("").to_owned();
                    if name.starts_with(&self.prefix) {
                        valid_name(&name)?;
                        self.ids.insert(name.clone(), name);
                    }
                }
            }
            Provider::S3 { prefix, .. } | Provider::R2 { prefix, .. } => {
                let full_prefix = format!(
                    "{}{}{}",
                    prefix.trim_matches('/'),
                    if prefix.trim_matches('/').is_empty() {
                        ""
                    } else {
                        "/"
                    },
                    self.prefix
                );
                let mut continuation = String::new();
                loop {
                    pages += 1;
                    if pages > 10000 {
                        return Err(err("syncSize", "云端分页超过限制，未应用不完整目录。"));
                    }
                    let mut query = vec![
                        ("list-type".into(), "2".into()),
                        ("prefix".into(), full_prefix.clone()),
                    ];
                    if !continuation.is_empty() {
                        query.push(("continuation-token".into(), continuation.clone()));
                    }
                    let (status, bytes) = self.read(self.s3(Method::GET, "", &query, &[])?)?;
                    if status != 200 {
                        return Err(err("syncS3", "S3 列表请求失败，请检查存储桶、区域和权限。"));
                    }
                    for key in xml_values(&bytes, b"Key")? {
                        let name = key.rsplit('/').next().unwrap_or("");
                        if name.starts_with(&self.prefix) {
                            valid_name(name)?;
                            self.ids.insert(name.into(), key);
                        }
                    }
                    if !xml_values(&bytes, b"IsTruncated")?
                        .iter()
                        .any(|s| s == "true")
                    {
                        break;
                    }
                    let next = xml_values(&bytes, b"NextContinuationToken")?
                        .into_iter()
                        .next()
                        .ok_or_else(|| err("syncResponse", "S3 分页标记缺失。"))?;
                    if next == continuation {
                        return Err(err("syncResponse", "S3 分页没有前进。"));
                    }
                    continuation = next;
                }
            }
            Provider::Unavailable => unreachable!("validated by Backend::new"),
        }
        Ok(self.ids.keys().cloned().collect())
    }
    fn get(&mut self, name: &str) -> Result<Option<Vec<u8>>> {
        valid_name(name)?;
        match self.provider.clone() {
            Provider::Folder { path } => match std::fs::read(path.join(name)) {
                Ok(data) => {
                    if data.len() > LIMIT {
                        return Err(err("syncSize", "同步对象过大。"));
                    }
                    Ok(Some(data))
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(_) => Err(err("syncIO", "无法读取同步对象。")),
            },
            provider => {
                let request = match provider {
                    Provider::Webdav { .. } => self.webdav(Method::GET, name),
                    Provider::S3 { .. } | Provider::R2 { .. } => {
                        self.s3(Method::GET, name, &[], &[])?
                    }
                    _ => unreachable!(),
                };
                let response = self.send(request)?;
                if let Some(time) = response
                    .headers()
                    .get("date")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|s| chrono::DateTime::parse_from_rfc2822(s).ok())
                {
                    self.clock = Some(time.timestamp());
                }
                response_bytes(response)
            }
        }
    }
    fn put(&mut self, name: &str, data: &[u8]) -> Result<()> {
        valid_name(name)?;
        if data.len() > 512 * 1024 {
            return Err(err("syncSize", "同步对象需要分块后上传。"));
        }
        if let Some(existing) = self.get(name)? {
            if existing == data {
                return Ok(());
            }
            return Err(err("syncCollision", "云端同名对象内容不同，已停止覆盖。"));
        }
        match self.provider.clone() {
            Provider::Folder { path } => {
                // Android's app sandbox does not reliably permit hard links.
                // Content-addressed names make a racing replacement idempotent:
                // two valid writers of this name necessarily publish the same bytes.
                if !name.ends_with(&format!("-{}.tps", hex::encode(Sha256::digest(data)))) {
                    return Err(err("syncIntegrity", "本地同步对象名称与内容校验不一致。"));
                }
                let temp = path.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
                let mut opts = std::fs::OpenOptions::new();
                opts.write(true).create_new(true);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    opts.mode(0o600);
                }
                let mut file = opts
                    .open(&temp)
                    .map_err(|_| err("syncIO", "无法保存同步对象。"))?;
                file.write_all(data)
                    .and_then(|_| file.sync_all())
                    .map_err(|_| err("syncIO", "同步对象未完整写入。"))?;
                let result = std::fs::rename(&temp, path.join(name));
                let _ = std::fs::remove_file(temp);
                if let Err(e) = result {
                    if e.kind() != std::io::ErrorKind::AlreadyExists {
                        return Err(err("syncIO", "无法发布同步对象。"));
                    }
                }
                #[cfg(unix)]
                std::fs::File::open(&path)
                    .and_then(|f| f.sync_all())
                    .map_err(|_| err("syncIO", "无法确认本地同步目录已保存。"))?;
            }
            provider => {
                let request = match provider {
                    Provider::Webdav { .. } => self
                        .webdav(Method::PUT, name)
                        .header("if-none-match", "*")
                        .body(data.to_vec()),
                    Provider::S3 { .. } | Provider::R2 { .. } => self
                        .s3(Method::PUT, name, &[], data)?
                        .header("if-none-match", "*"),
                    _ => unreachable!(),
                };
                let (status, _) =
                    self.read(request.header("content-type", "application/octet-stream"))?;
                if !(200..300).contains(&status) && status != 412 {
                    return Err(err("syncHTTP", "上传失败，本机队列已保留。"));
                }
            }
        }
        self.verify(name, data)
    }
    fn server_time(&self) -> Option<i64> {
        self.clock
    }
    fn check_conditionals(&mut self, library: &str) -> Result<()> {
        if matches!(self.provider, Provider::Folder { .. }) {
            return Ok(());
        }
        let name = format!("tp1-{library}-probe-{}.tps", uuid::Uuid::new_v4());
        let initial = uuid::Uuid::new_v4().as_bytes().to_vec();
        if !self.compare_exchange(&name, None, &initial)? {
            return Err(err("syncConditionalWrite", "云服务不能创建条件控制对象。"));
        }
        for header in ["if-none-match", "if-match"] {
            let request = match &self.provider {
                Provider::Webdav { .. } => self.webdav(Method::PUT, &name).body(vec![0; 16]),
                Provider::S3 { .. } | Provider::R2 { .. } => {
                    self.s3(Method::PUT, &name, &[], &[0; 16])?
                }
                _ => unreachable!(),
            }
            .header(
                header,
                if header == "if-none-match" {
                    "*"
                } else {
                    "\"termpilot-deliberately-stale-etag\""
                },
            );
            let (status, _) = self.read(request)?;
            if status != 412 || self.get(&name)?.as_deref() != Some(initial.as_slice()) {
                return Err(err(
                    "syncConditionalWrite",
                    "云服务未严格执行条件写入，已拒绝修改 Key 以保护数据。",
                ));
            }
        }
        let replacement = uuid::Uuid::new_v4().as_bytes().to_vec();
        if !self.compare_exchange(&name, Some(&initial), &replacement)? {
            return Err(err(
                "syncConditionalWrite",
                "云服务无法按当前版本提交条件更新，尚未开始修改 Key。",
            ));
        }
        Ok(())
    }
    fn compare_exchange(
        &mut self,
        name: &str,
        expected: Option<&[u8]>,
        data: &[u8],
    ) -> Result<bool> {
        valid_name(name)?;
        if data.len() > 64 * 1024 {
            return Err(err("syncSize", "同步控制信息过大。"));
        }
        if let Provider::Folder { path } = &self.provider {
            // SQLite supplies a cross-process lock without relying on flock(),
            // which is unavailable on some Android filesystems.
            let mut db = rusqlite::Connection::open(path.join(".termpilot-control.sqlite"))
                .map_err(super::db_error)?;
            db.busy_timeout(Duration::from_secs(5))
                .map_err(super::db_error)?;
            let tx = db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(super::db_error)?;
            let previous = match std::fs::read(path.join(name)) {
                Ok(bytes) => Some(bytes),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
                Err(_) => return Err(err("syncIO", "无法读取同步控制信息。")),
            };
            if previous.as_deref() != expected {
                return Ok(false);
            }
            let temp = path.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
            let mut options = std::fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options
                .open(&temp)
                .map_err(|_| err("syncIO", "无法写入同步控制信息。"))?;
            file.write_all(data)
                .and_then(|_| file.sync_all())
                .map_err(|_| err("syncIO", "同步控制信息未完整保存。"))?;
            std::fs::rename(&temp, path.join(name))
                .map_err(|_| err("syncIO", "无法提交同步控制信息。"))?;
            #[cfg(unix)]
            std::fs::File::open(path)
                .and_then(|f| f.sync_all())
                .map_err(|_| err("syncIO", "无法确认同步控制信息。"))?;
            tx.commit().map_err(super::db_error)?;
            return Ok(true);
        }
        let etag = {
            // Apache emits a weak validator for a file modified in the current
            // second. Re-fetch after a bounded wait; never strip W/ or perform
            // an unconditional write.
            let mut attempt = 0;
            loop {
                let request = match &self.provider {
                    Provider::Webdav { .. } => self.webdav(Method::GET, name),
                    Provider::S3 { .. } | Provider::R2 { .. } => {
                        self.s3(Method::GET, name, &[], &[])?
                    }
                    _ => return Err(err("syncProvider", "同步服务不可用。")),
                };
                let response = self.send(request)?;
                let etag = response
                    .headers()
                    .get("etag")
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_owned);
                let previous = response_bytes(response)?;
                if previous.as_deref() != expected {
                    return Ok(false);
                }
                if expected.is_some()
                    && etag.as_ref().is_some_and(|v| v.starts_with("W/"))
                    && attempt < 4
                {
                    attempt += 1;
                    std::thread::sleep(Duration::from_millis(600));
                    continue;
                }
                break etag;
            }
        };
        let mut request = match &self.provider {
            Provider::Webdav { .. } => self.webdav(Method::PUT, name).body(data.to_vec()),
            _ => self.s3(Method::PUT, name, &[], data)?,
        };
        request = if expected.is_some() {
            let tag = etag
                .filter(|v| !v.starts_with("W/") && !v.is_empty())
                .ok_or_else(|| {
                    err(
                        "syncConditionalWrite",
                        "云服务没有提供强 ETag，无法安全切换同步 Key。",
                    )
                })?;
            request.header("if-match", tag)
        } else {
            request.header("if-none-match", "*")
        };
        let (status, _) = self.read(request.header("content-type", "application/octet-stream"))?;
        if status == 412 || status == 409 {
            return Ok(false);
        }
        if !(200..300).contains(&status) {
            return Err(err(
                "syncConditionalWrite",
                "云服务条件写入失败，同步版本未切换。",
            ));
        }
        Ok(self.get(name)?.as_deref() == Some(data))
    }
}
fn response_bytes(mut response: Response) -> Result<Option<Vec<u8>>> {
    let status = response.status().as_u16();
    if status == 404 {
        return Ok(None);
    }
    if !(200..300).contains(&status) {
        return Err(err(
            if status == 401 || status == 403 {
                "syncAuth"
            } else {
                "syncHTTP"
            },
            "下载失败，请检查授权或服务状态。",
        ));
    }
    let mut bytes = Vec::new();
    (&mut response)
        .take((LIMIT + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| err("syncNetwork", "下载未完成。"))?;
    if bytes.len() > LIMIT {
        return Err(err("syncSize", "同步对象过大。"));
    }
    Ok(Some(bytes))
}
fn hmac(key: &[u8], message: &[u8]) -> Vec<u8> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).unwrap();
    mac.update(message);
    mac.finalize().into_bytes().to_vec()
}
fn encode(text: &str) -> String {
    text.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}
fn encode_path(text: &str) -> String {
    text.split('/').map(encode).collect::<Vec<_>>().join("/")
}
fn xml_values(bytes: &[u8], tag: &[u8]) -> Result<Vec<String>> {
    use quick_xml::{events::Event, Reader};
    let mut reader = Reader::from_reader(bytes);
    let mut values = Vec::new();
    let mut text = None::<String>;
    loop {
        match reader
            .read_event()
            .map_err(|_| err("syncResponse", "云端 XML 格式无效。"))?
        {
            Event::Start(e) if e.local_name().as_ref().as_bytes() == tag => {
                text = Some(String::new())
            }
            Event::Text(e) => {
                if let Some(value) = text.as_mut() {
                    value.push_str(&e.xml10_content());
                }
            }
            Event::CData(e) => {
                if let Some(value) = text.as_mut() {
                    value.push_str(e.as_ref());
                }
            }
            Event::GeneralRef(e) => {
                if let Some(value) = text.as_mut() {
                    let entity = format!("&{};", e.as_ref());
                    value.push_str(
                        &quick_xml::escape::unescape(&entity)
                            .map_err(|_| err("syncResponse", "XML 转义无效。"))?,
                    );
                }
            }
            Event::End(e) if e.local_name().as_ref().as_bytes() == tag => {
                if let Some(value) = text.take() {
                    values.push(value);
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    Ok(values)
}
#[cfg(test)]
#[path = "transport_tests.rs"]
mod tests;
