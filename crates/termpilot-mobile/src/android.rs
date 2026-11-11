//! JNI owns copies only. Rust pointers never cross into Kotlin.
use jni::{
    objects::{JByteArray, JClass, JString},
    sys::{jbyteArray, jint, jlong, jstring},
    JNIEnv,
};
use std::{ffi::CString, ptr};
use zeroize::Zeroize;
#[no_mangle]
pub extern "system" fn Java_com_termpilot_app_NativeBridge_create(
    mut env: JNIEnv,
    _: JClass,
    path: JString,
    key: JByteArray,
) -> jlong {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let path: String = env.get_string(&path).ok()?.into();
        let path = CString::new(path).ok()?;
        let mut key = env.convert_byte_array(key).ok()?;
        let id = unsafe { super::tp_mobile_create(path.as_ptr(), key.as_ptr(), key.len()) };
        key.zeroize();
        Some(id as jlong)
    }));
    result.ok().flatten().unwrap_or(0)
}
#[no_mangle]
pub extern "system" fn Java_com_termpilot_app_NativeBridge_call(
    mut env: JNIEnv,
    _: JClass,
    id: jlong,
    request: JString,
) -> jstring {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut request: String = env.get_string(&request).ok()?.into();
        let result = super::call(id as u64, request.as_bytes());
        request.zeroize();
        env.new_string(result).ok().map(|s| s.into_raw())
    }));
    result.ok().flatten().unwrap_or(ptr::null_mut())
}
#[no_mangle]
pub extern "system" fn Java_com_termpilot_app_NativeBridge_poll(
    env: JNIEnv,
    _: JClass,
    id: jlong,
    timeout: jint,
) -> jbyteArray {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let p = super::client(id as u64)
            .ok()?
            .events
            .poll(std::time::Duration::from_millis(
                timeout.clamp(0, 1000) as u64
            ))?;
        env.byte_array_from_slice(&p.encode())
            .ok()
            .map(|a| a.into_raw())
    }));
    result.ok().flatten().unwrap_or(ptr::null_mut())
}
#[no_mangle]
pub extern "system" fn Java_com_termpilot_app_NativeBridge_destroy(
    _: JNIEnv,
    _: JClass,
    id: jlong,
) {
    super::tp_mobile_destroy(id as u64);
}
