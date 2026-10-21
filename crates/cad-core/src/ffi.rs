//! Single-owner, serialized document API. Strings and batches are owned by Rust;
//! callers must release them with the corresponding free function, once only.
use crate::{
    commands::Engine,
    geometry::{Bounds, Point},
    render::{Batch, Segment, Triangle},
};
use std::{
    ffi::{c_char, CStr, CString},
    panic::{catch_unwind, AssertUnwindSafe},
    ptr,
};

#[no_mangle]
pub extern "C" fn cad_create() -> *mut Engine {
    Box::into_raw(Box::new(Engine::default()))
}
/// # Safety
/// `engine` is null or a live handle from cad_create. No concurrent access.
#[no_mangle]
pub unsafe extern "C" fn cad_destroy(engine: *mut Engine) {
    if !engine.is_null() {
        drop(Box::from_raw(engine));
    }
}
/// # Safety
/// engine must be live and exclusively accessed; request must be a NUL-terminated
/// UTF-8 string. The result is owned and must be passed to cad_string_free.
#[no_mangle]
pub unsafe extern "C" fn cad_request(engine: *mut Engine, request: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<serde_json::Value, String> {
        if engine.is_null() || request.is_null() {
            return Err("Null engine or request".into());
        }
        let bytes = CStr::from_ptr(request).to_bytes();
        if bytes.len() > 128 * 1024 * 1024 {
            return Err("Request exceeds 128 MiB".into());
        }
        let v = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        (*engine).dispatch(v)
    }));
    let response = match result {
        Ok(Ok(value)) => serde_json::json!({"ok":true,"value":value}),
        Ok(Err(error)) => serde_json::json!({"ok":false,"error":error}),
        Err(_) => {
            serde_json::json!({"ok":false,"error":"Engine panic contained at C boundary; reopen document before continuing"})
        }
    };
    CString::new(response.to_string())
        .expect("JSON contains no raw NUL")
        .into_raw()
}
/// # Safety
/// string must be null or a string returned by cad_request/cad_batch_labels,
/// not already freed.
#[no_mangle]
pub unsafe extern "C" fn cad_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(CString::from_raw(string));
    }
}
/// # Safety
/// engine must be a live handle and cannot be accessed concurrently.
#[no_mangle]
pub unsafe extern "C" fn cad_render(
    engine: *const Engine,
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,
    tolerance: f64,
) -> *mut Batch {
    if engine.is_null()
        || ![min_x, min_y, max_x, max_y, tolerance]
            .iter()
            .all(|v| v.is_finite())
        || min_x > max_x
        || min_y > max_y
        || tolerance <= 0.0
    {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new((*engine).batch(
            Bounds {
                min: Point::new(min_x, min_y),
                max: Point::new(max_x, max_y),
            },
            tolerance,
        )))
    }))
    .unwrap_or(ptr::null_mut())
}
/// # Safety
/// batch is null or a live, not-yet-freed batch from cad_render.
#[no_mangle]
pub unsafe extern "C" fn cad_render_plain(
    engine: *const Engine,
    min_x: f64,
    min_y: f64,
    max_x: f64,
    max_y: f64,
    tolerance: f64,
) -> *mut Batch {
    if engine.is_null()
        || ![min_x, min_y, max_x, max_y, tolerance]
            .iter()
            .all(|v| v.is_finite())
        || min_x > max_x
        || min_y > max_y
        || tolerance <= 0.0
    {
        return ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        Box::into_raw(Box::new((*engine).batch_mode(
            Bounds {
                min: Point::new(min_x, min_y),
                max: Point::new(max_x, max_y),
            },
            tolerance,
            false,
        )))
    }))
    .unwrap_or(ptr::null_mut())
}
/// # Safety
/// batch is null or a live, not-yet-freed batch from cad_render.
#[no_mangle]
pub unsafe extern "C" fn cad_batch_free(batch: *mut Batch) {
    if !batch.is_null() {
        drop(Box::from_raw(batch));
    }
}
/// # Safety
/// batch is live; returned memory is valid only until cad_batch_free.
#[no_mangle]
pub unsafe extern "C" fn cad_batch_segments(
    batch: *const Batch,
    count: *mut usize,
) -> *const Segment {
    if batch.is_null() || count.is_null() {
        return ptr::null();
    }
    *count = (*batch).segments.len();
    (*batch).segments.as_ptr()
}
/// # Safety
/// batch is live; returned memory is valid only until cad_batch_free.
#[no_mangle]
pub unsafe extern "C" fn cad_batch_triangles(
    batch: *const Batch,
    count: *mut usize,
) -> *const Triangle {
    if batch.is_null() || count.is_null() {
        return ptr::null();
    }
    *count = (*batch).triangles.len();
    (*batch).triangles.as_ptr()
}
/// # Safety
/// batch is live; returned string is owned and must be freed with cad_string_free.
#[no_mangle]
pub unsafe extern "C" fn cad_batch_labels(batch: *const Batch) -> *mut c_char {
    if batch.is_null() {
        return ptr::null_mut();
    }
    CString::new(serde_json::to_string(&(*batch).labels).unwrap_or_else(|_| "[]".into()))
        .expect("JSON NUL escaped")
        .into_raw()
}
