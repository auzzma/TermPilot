//! Explorer drag source. CF_HDROP is rendered on demand: the protocol worker
//! receives files into a private staging directory before Explorer can copy them.
#[cfg(windows)]
mod native {
    use std::{path::PathBuf, sync::Mutex};
    use windows::{
        core::{implement, Ref, Result, BOOL, HRESULT},
        Win32::{
            Foundation::*,
            System::{Com::*, Memory::*, Ole::*, SystemServices::MODIFIERKEYS_FLAGS},
            UI::Shell::SHCreateStdEnumFmtEtc,
        },
    };
    type Fetch = Box<dyn Fn() -> std::result::Result<Vec<PathBuf>, String> + Send>;
    #[implement(IDataObject)]
    struct Data {
        fetch: Fetch,
        paths: Mutex<Option<Vec<PathBuf>>>,
    }
    fn supported(p: *const FORMATETC) -> bool {
        if p.is_null() {
            return false;
        }
        let p = unsafe { &*p };
        p.cfFormat == 15
            && p.tymed & TYMED_HGLOBAL.0 as u32 != 0
            && p.dwAspect == DVASPECT_CONTENT.0
            && p.lindex == -1
    }
    fn no() -> windows::core::Error {
        E_NOTIMPL.into()
    }
    impl IDataObject_Impl for Data_Impl {
        fn GetData(&self, p: *const FORMATETC) -> Result<STGMEDIUM> {
            if !supported(p) {
                return Err(DV_E_FORMATETC.into());
            }
            let mut paths = self.paths.lock().unwrap();
            if paths.is_none() {
                *paths = Some((self.fetch)().map_err(|_| windows::core::Error::from(E_FAIL))?);
            }
            let mut bytes = vec![0u8; 20];
            bytes[..4].copy_from_slice(&20u32.to_le_bytes());
            bytes[16..20].copy_from_slice(&1u32.to_le_bytes());
            for path in paths.as_ref().unwrap() {
                use std::os::windows::ffi::OsStrExt;
                for c in path.as_os_str().encode_wide().chain(Some(0)) {
                    bytes.extend(c.to_le_bytes());
                }
            }
            bytes.extend([0, 0]);
            unsafe {
                let memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes.len())?;
                let address = GlobalLock(memory);
                if address.is_null() {
                    let _ = GlobalFree(Some(memory));
                    return Err(E_OUTOFMEMORY.into());
                }
                std::ptr::copy_nonoverlapping(bytes.as_ptr(), address.cast(), bytes.len());
                let _ = GlobalUnlock(memory);
                Ok(STGMEDIUM {
                    tymed: TYMED_HGLOBAL.0 as u32,
                    u: STGMEDIUM_0 { hGlobal: memory },
                    pUnkForRelease: std::mem::ManuallyDrop::new(None),
                })
            }
        }
        fn GetDataHere(&self, _: *const FORMATETC, _: *mut STGMEDIUM) -> Result<()> {
            Err(no())
        }
        fn QueryGetData(&self, p: *const FORMATETC) -> HRESULT {
            if supported(p) {
                S_OK
            } else {
                DV_E_FORMATETC
            }
        }
        fn GetCanonicalFormatEtc(&self, _: *const FORMATETC, p: *mut FORMATETC) -> HRESULT {
            if !p.is_null() {
                unsafe {
                    (*p).ptd = std::ptr::null_mut();
                }
            }
            E_NOTIMPL
        }
        fn SetData(&self, _: *const FORMATETC, _: *const STGMEDIUM, _: BOOL) -> Result<()> {
            Err(no())
        }
        fn EnumFormatEtc(&self, d: u32) -> Result<IEnumFORMATETC> {
            if d != DATADIR_GET.0 as u32 {
                return Err(no());
            }
            unsafe {
                SHCreateStdEnumFmtEtc(&[FORMATETC {
                    cfFormat: 15,
                    ptd: std::ptr::null_mut(),
                    dwAspect: DVASPECT_CONTENT.0,
                    lindex: -1,
                    tymed: TYMED_HGLOBAL.0 as u32,
                }])
            }
        }
        fn DAdvise(&self, _: *const FORMATETC, _: u32, _: Ref<IAdviseSink>) -> Result<u32> {
            Err(OLE_E_ADVISENOTSUPPORTED.into())
        }
        fn DUnadvise(&self, _: u32) -> Result<()> {
            Err(OLE_E_ADVISENOTSUPPORTED.into())
        }
        fn EnumDAdvise(&self) -> Result<IEnumSTATDATA> {
            Err(OLE_E_ADVISENOTSUPPORTED.into())
        }
    }
    #[implement(IDropSource)]
    struct Source;
    impl IDropSource_Impl for Source_Impl {
        fn QueryContinueDrag(&self, escape: BOOL, state: MODIFIERKEYS_FLAGS) -> HRESULT {
            if escape.as_bool() {
                DRAGDROP_S_CANCEL
            } else if state.0 & 1 == 0 {
                DRAGDROP_S_DROP
            } else {
                S_OK
            }
        }
        fn GiveFeedback(&self, _: DROPEFFECT) -> HRESULT {
            DRAGDROP_S_USEDEFAULTCURSORS
        }
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn file_data_is_deferred_and_unicode_paths_are_cached() {
            use std::sync::{Arc,atomic::{AtomicUsize,Ordering}};
            let calls=Arc::new(AtomicUsize::new(0));let called=calls.clone();
            let data:IDataObject=Data{fetch:Box::new(move||{called.fetch_add(1,Ordering::Relaxed);Ok(vec![PathBuf::from(r"C:\TermPilot-test\中文.txt")])}),paths:Mutex::new(None)}.into();
            let format=FORMATETC{cfFormat:15,ptd:std::ptr::null_mut(),dwAspect:DVASPECT_CONTENT.0,lindex:-1,tymed:TYMED_HGLOBAL.0 as u32};
            unsafe {
                assert_eq!(data.QueryGetData(&format),S_OK);
                assert_eq!(calls.load(Ordering::Relaxed),0);
                for _ in 0..2 {
                    let mut medium=data.GetData(&format).unwrap();let memory=medium.u.hGlobal;let p=GlobalLock(memory).cast::<u8>();assert!(!p.is_null());
                    assert_eq!(u32::from_le_bytes(std::slice::from_raw_parts(p,4).try_into().unwrap()),20);
                    let path=r"C:\TermPilot-test\中文.txt";
                    let text=std::slice::from_raw_parts(p.add(20).cast::<u16>(),path.encode_utf16().count());assert_eq!(String::from_utf16(text).unwrap(),path);
                    let _=GlobalUnlock(memory);ReleaseStgMedium(&mut medium);
                }
                assert_eq!(calls.load(Ordering::Relaxed),1);
            }
        }
    }
    pub fn run(
        fetch: impl Fn() -> std::result::Result<Vec<PathBuf>, String> + Send + 'static,
    ) -> std::result::Result<(), String> {
        unsafe {
            OleInitialize(None).map_err(|e| e.to_string())?;
        }
        struct Ole;
        impl Drop for Ole {
            fn drop(&mut self) {
                unsafe {
                    OleUninitialize();
                }
            }
        }
        let _ole = Ole;
        let data: IDataObject = Data {
            fetch: Box::new(fetch),
            paths: Mutex::new(None),
        }
        .into();
        let source: IDropSource = Source.into();
        let mut effect = DROPEFFECT_NONE;
        let status = unsafe { DoDragDrop(&data, &source, DROPEFFECT_COPY, &mut effect) };
        if status.is_err() {
            return Err(status.to_string());
        }
        Ok(())
    }
}
#[cfg(windows)]
pub use native::run;
#[cfg(not(windows))]
pub fn run(
    _: impl Fn() -> Result<Vec<std::path::PathBuf>, String> + Send + 'static,
) -> Result<(), String> {
    Err("Windows Explorer drag adapter unavailable".into())
}
