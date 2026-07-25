//! Versioned C ABI used by the Flutter desktop client.
//!
//! Every exported operation catches Rust panics. Buffers returned by this
//! module must be released with `yappa_mls_buffer_free`; device handles must be
//! released with `yappa_mls_device_free`.

use crate::{
    DecryptedApplication, GroupMember, MAX_APPLICATION_BYTES, MAX_GROUP_ID_BYTES,
    MAX_IDENTITY_BYTES, MAX_STATE_BYTES, MAX_WIRE_BYTES, MlsDevice,
    OutgoingApplication, PreparedAdd, PreparedCommit, YAPPA_MLS_ABI_VERSION,
    YappaMlsError,
};
use core::{ptr, slice};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Mutex, MutexGuard};

const WRAPPING_KEY_BYTES: usize = 32;
const MAX_ENCRYPTED_STATE_INPUT_BYTES: usize = MAX_STATE_BYTES + 64;

pub struct YappaMlsHandle {
    device: Mutex<MlsDevice>,
}

#[repr(C)]
pub struct YappaMlsBuffer {
    pub data: *mut u8,
    pub len: usize,
}

impl Default for YappaMlsBuffer {
    fn default() -> Self {
        Self {
            data: ptr::null_mut(),
            len: 0,
        }
    }
}

#[repr(C)]
pub struct YappaMlsResult {
    pub code: i32,
    pub value: u64,
    pub buffer: YappaMlsBuffer,
}

impl YappaMlsResult {
    fn success(value: u64, bytes: Vec<u8>) -> Self {
        Self {
            code: 0,
            value,
            buffer: into_buffer(bytes),
        }
    }

    fn error(error: YappaMlsError) -> Self {
        Self {
            code: error_code(error),
            value: 0,
            buffer: YappaMlsBuffer::default(),
        }
    }

    fn panic() -> Self {
        Self {
            code: 100,
            value: 0,
            buffer: YappaMlsBuffer::default(),
        }
    }
}

fn error_code(error: YappaMlsError) -> i32 {
    match error {
        YappaMlsError::InvalidInput => 1,
        YappaMlsError::MissingState => 2,
        YappaMlsError::StateConflict => 3,
        YappaMlsError::InvalidWireMessage => 4,
        YappaMlsError::UnexpectedMessageClass => 5,
        YappaMlsError::CryptographicFailure => 6,
    }
}

fn into_buffer(bytes: Vec<u8>) -> YappaMlsBuffer {
    if bytes.is_empty() {
        return YappaMlsBuffer::default();
    }
    let mut bytes = bytes.into_boxed_slice();
    let result = YappaMlsBuffer {
        data: bytes.as_mut_ptr(),
        len: bytes.len(),
    };
    core::mem::forget(bytes);
    result
}

unsafe fn input<'a>(
    data: *const u8,
    len: usize,
    max: usize,
) -> Result<&'a [u8], YappaMlsError> {
    if data.is_null() || len == 0 || len > max {
        return Err(YappaMlsError::InvalidInput);
    }
    // SAFETY: The C ABI contract requires a readable allocation of `len`
    // bytes that remains alive for the duration of the call.
    Ok(unsafe { slice::from_raw_parts(data, len) })
}

unsafe fn device<'a>(
    handle: *mut YappaMlsHandle,
) -> Result<MutexGuard<'a, MlsDevice>, YappaMlsError> {
    // SAFETY: Handles are created and exclusively owned by this ABI.
    unsafe { handle.as_ref() }
        .ok_or(YappaMlsError::InvalidInput)?
        .device
        .lock()
        .map_err(|_| YappaMlsError::CryptographicFailure)
}

fn invoke(operation: impl FnOnce() -> Result<YappaMlsResult, YappaMlsError>) -> YappaMlsResult {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => YappaMlsResult::error(error),
        Err(_) => YappaMlsResult::panic(),
    }
}

fn write_u32(output: &mut Vec<u8>, value: usize) -> Result<(), YappaMlsError> {
    let value = u32::try_from(value).map_err(|_| YappaMlsError::InvalidInput)?;
    output.extend_from_slice(&value.to_be_bytes());
    Ok(())
}

fn write_bytes(output: &mut Vec<u8>, value: &[u8]) -> Result<(), YappaMlsError> {
    write_u32(output, value.len())?;
    output.extend_from_slice(value);
    Ok(())
}

fn encode_prepared_add(value: PreparedAdd) -> Result<Vec<u8>, YappaMlsError> {
    let mut output = Vec::with_capacity(16 + 8 + value.commit.len() + value.welcome.len());
    output.extend_from_slice(&value.parent_epoch.to_be_bytes());
    output.extend_from_slice(&value.accepted_epoch.to_be_bytes());
    write_bytes(&mut output, &value.commit)?;
    write_bytes(&mut output, &value.welcome)?;
    Ok(output)
}

fn encode_prepared_commit(value: PreparedCommit) -> Result<Vec<u8>, YappaMlsError> {
    let mut output = Vec::with_capacity(16 + 4 + value.commit.len());
    output.extend_from_slice(&value.parent_epoch.to_be_bytes());
    output.extend_from_slice(&value.accepted_epoch.to_be_bytes());
    write_bytes(&mut output, &value.commit)?;
    Ok(output)
}

fn encode_application(value: DecryptedApplication) -> Result<Vec<u8>, YappaMlsError> {
    let mut output =
        Vec::with_capacity(
            8 + 12
                + value.sender_credential.len()
                + value.sender_signature_public_key.len()
                + value.plaintext.len(),
        );
    output.extend_from_slice(&value.epoch.to_be_bytes());
    write_bytes(&mut output, &value.sender_credential)?;
    write_bytes(&mut output, &value.sender_signature_public_key)?;
    write_bytes(&mut output, &value.plaintext)?;
    Ok(output)
}

fn encode_members(values: Vec<GroupMember>) -> Result<Vec<u8>, YappaMlsError> {
    let mut output = Vec::new();
    write_u32(&mut output, values.len())?;
    for member in values {
        write_bytes(&mut output, &member.credential)?;
        write_bytes(&mut output, &member.signature_public_key)?;
    }
    Ok(output)
}

fn encode_outgoing(value: &OutgoingApplication) -> Result<Vec<u8>, YappaMlsError> {
    let mut output = Vec::new();
    write_bytes(&mut output, &value.group_id)?;
    write_bytes(&mut output, &value.operation_id)?;
    output.extend_from_slice(&value.epoch.to_be_bytes());
    write_bytes(&mut output, &value.plaintext)?;
    write_bytes(&mut output, &value.wire)?;
    Ok(output)
}

fn encode_outgoing_list(
    values: Vec<OutgoingApplication>,
) -> Result<Vec<u8>, YappaMlsError> {
    let mut output = Vec::new();
    write_u32(&mut output, values.len())?;
    for value in values {
        write_bytes(&mut output, &encode_outgoing(&value)?)?;
    }
    Ok(output)
}

#[unsafe(no_mangle)]
pub extern "C" fn yappa_mls_abi_version() -> u32 {
    YAPPA_MLS_ABI_VERSION
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_buffer_free(buffer: YappaMlsBuffer) {
    if buffer.data.is_null() || buffer.len == 0 {
        return;
    }
    // SAFETY: `into_buffer` allocates exactly this boxed slice and transfers
    // exclusive ownership to the caller.
    drop(unsafe { Box::from_raw(slice::from_raw_parts_mut(buffer.data, buffer.len)) });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_device_new(
    identity: *const u8,
    identity_len: usize,
) -> *mut YappaMlsHandle {
    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: Validated against the ABI input contract.
        let identity = unsafe { input(identity, identity_len, MAX_IDENTITY_BYTES) }?;
        MlsDevice::new(identity)
    })) {
        Ok(Ok(device)) => Box::into_raw(Box::new(YappaMlsHandle {
            device: Mutex::new(device),
        })),
        _ => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_device_import(
    wrapping_key: *const u8,
    context: *const u8,
    context_len: usize,
    encrypted: *const u8,
    encrypted_len: usize,
) -> *mut YappaMlsHandle {
    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: Validated against the ABI input contract.
        let key = unsafe { input(wrapping_key, WRAPPING_KEY_BYTES, WRAPPING_KEY_BYTES) }?;
        let key: &[u8; WRAPPING_KEY_BYTES] =
            key.try_into().map_err(|_| YappaMlsError::InvalidInput)?;
        // SAFETY: Validated against the ABI input contract.
        let context = unsafe { input(context, context_len, MAX_IDENTITY_BYTES) }?;
        // SAFETY: Validated against the ABI input contract.
        let encrypted =
            unsafe { input(encrypted, encrypted_len, MAX_ENCRYPTED_STATE_INPUT_BYTES) }?;
        MlsDevice::import_encrypted_state(key, context, encrypted)
    })) {
        Ok(Ok(device)) => Box::into_raw(Box::new(YappaMlsHandle {
            device: Mutex::new(device),
        })),
        _ => ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_device_free(handle: *mut YappaMlsHandle) {
    if handle.is_null() {
        return;
    }
    // SAFETY: The caller must pass a live handle exactly once.
    drop(unsafe { Box::from_raw(handle) });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_signature_public_key(
    handle: *mut YappaMlsHandle,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI handle contract.
        let device = unsafe { device(handle) }?;
        Ok(YappaMlsResult::success(
            0,
            device.signature_public_key().to_vec(),
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_export_state(
    handle: *mut YappaMlsHandle,
    wrapping_key: *const u8,
    context: *const u8,
    context_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let device = unsafe { device(handle) }?;
        let key = unsafe { input(wrapping_key, WRAPPING_KEY_BYTES, WRAPPING_KEY_BYTES) }?;
        let key: &[u8; WRAPPING_KEY_BYTES] =
            key.try_into().map_err(|_| YappaMlsError::InvalidInput)?;
        let context = unsafe { input(context, context_len, MAX_IDENTITY_BYTES) }?;
        Ok(YappaMlsResult::success(
            0,
            device.export_encrypted_state(key, context)?,
        ))
    })
}

macro_rules! group_result {
    ($name:ident, $method:ident) => {
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(
            handle: *mut YappaMlsHandle,
            group_id: *const u8,
            group_id_len: usize,
        ) -> YappaMlsResult {
            invoke(|| {
                // SAFETY: Validated against the ABI contracts.
                let device = unsafe { device(handle) }?;
                let group_id = unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
                Ok(YappaMlsResult::success(device.$method(group_id)?, Vec::new()))
            })
        }
    };
}

group_result!(yappa_mls_create_group, create_group);
group_result!(yappa_mls_accept_pending_commit, accept_pending_commit);
group_result!(yappa_mls_reject_pending_commit, reject_pending_commit);
group_result!(yappa_mls_epoch, epoch);

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_generate_key_package(
    handle: *mut YappaMlsHandle,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI handle contract.
        let device = unsafe { device(handle) }?;
        Ok(YappaMlsResult::success(0, device.generate_key_package()?))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_prepare_add(
    handle: *mut YappaMlsHandle,
    group_id: *const u8,
    group_id_len: usize,
    key_package: *const u8,
    key_package_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let device = unsafe { device(handle) }?;
        let group_id = unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
        let key_package = unsafe { input(key_package, key_package_len, MAX_WIRE_BYTES) }?;
        let prepared = device.prepare_add(group_id, key_package)?;
        Ok(YappaMlsResult::success(0, encode_prepared_add(prepared)?))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_prepare_self_update(
    handle: *mut YappaMlsHandle,
    group_id: *const u8,
    group_id_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let device = unsafe { device(handle) }?;
        let group_id = unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
        let prepared = device.prepare_self_update(group_id)?;
        Ok(YappaMlsResult::success(
            0,
            encode_prepared_commit(prepared)?,
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_prepare_remove(
    handle: *mut YappaMlsHandle,
    group_id: *const u8,
    group_id_len: usize,
    credential: *const u8,
    credential_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let device = unsafe { device(handle) }?;
        let group_id = unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
        let credential = unsafe { input(credential, credential_len, MAX_IDENTITY_BYTES) }?;
        let prepared = device.prepare_remove(group_id, credential)?;
        Ok(YappaMlsResult::success(
            0,
            encode_prepared_commit(prepared)?,
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_join_welcome(
    handle: *mut YappaMlsHandle,
    group_id: *const u8,
    group_id_len: usize,
    welcome: *const u8,
    welcome_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let device = unsafe { device(handle) }?;
        let group_id = unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
        let welcome = unsafe { input(welcome, welcome_len, MAX_WIRE_BYTES) }?;
        Ok(YappaMlsResult::success(
            device.join_from_welcome(group_id, welcome)?,
            Vec::new(),
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_process_commit(
    handle: *mut YappaMlsHandle,
    group_id: *const u8,
    group_id_len: usize,
    commit: *const u8,
    commit_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let device = unsafe { device(handle) }?;
        let group_id = unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
        let commit = unsafe { input(commit, commit_len, MAX_WIRE_BYTES) }?;
        Ok(YappaMlsResult::success(
            device.process_commit(group_id, commit)?,
            Vec::new(),
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_group_members(
    handle: *mut YappaMlsHandle,
    group_id: *const u8,
    group_id_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let device = unsafe { device(handle) }?;
        let group_id = unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
        Ok(YappaMlsResult::success(
            0,
            encode_members(device.group_members(group_id)?)?,
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_encrypt_application(
    handle: *mut YappaMlsHandle,
    group_id: *const u8,
    group_id_len: usize,
    plaintext: *const u8,
    plaintext_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let device = unsafe { device(handle) }?;
        let group_id = unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
        let plaintext = unsafe { input(plaintext, plaintext_len, MAX_APPLICATION_BYTES) }?;
        Ok(YappaMlsResult::success(
            0,
            device.encrypt_application(group_id, plaintext)?,
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_decrypt_application(
    handle: *mut YappaMlsHandle,
    group_id: *const u8,
    group_id_len: usize,
    wire: *const u8,
    wire_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let device = unsafe { device(handle) }?;
        let group_id = unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
        let wire = unsafe { input(wire, wire_len, MAX_WIRE_BYTES) }?;
        let application = device.decrypt_application(group_id, wire)?;
        Ok(YappaMlsResult::success(
            0,
            encode_application(application)?,
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_stage_application(
    handle: *mut YappaMlsHandle,
    group_id: *const u8,
    group_id_len: usize,
    sequenced_wire: *const u8,
    sequenced_wire_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let mut device = unsafe { device(handle) }?;
        let group_id =
            unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
        let sequenced_wire =
            unsafe { input(sequenced_wire, sequenced_wire_len, MAX_WIRE_BYTES + 8) }?;
        if sequenced_wire.len() <= 8 {
            return Err(YappaMlsError::InvalidInput);
        }
        let sequence = u64::from_be_bytes(
            sequenced_wire[..8]
                .try_into()
                .map_err(|_| YappaMlsError::InvalidInput)?,
        );
        let application =
            device.stage_application(group_id, sequence, &sequenced_wire[8..])?;
        Ok(YappaMlsResult::success(
            sequence,
            encode_application(application)?,
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_clear_staged_application(
    handle: *mut YappaMlsHandle,
    group_id: *const u8,
    group_id_len: usize,
    sequence: *const u8,
    sequence_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let mut device = unsafe { device(handle) }?;
        let group_id =
            unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
        let sequence = unsafe { input(sequence, sequence_len, 8) }?;
        if sequence.len() != 8 {
            return Err(YappaMlsError::InvalidInput);
        }
        let sequence = u64::from_be_bytes(
            sequence
                .try_into()
                .map_err(|_| YappaMlsError::InvalidInput)?,
        );
        Ok(YappaMlsResult::success(
            device.clear_staged_application(group_id, sequence)?,
            Vec::new(),
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_stage_outgoing_application(
    handle: *mut YappaMlsHandle,
    group_id: *const u8,
    group_id_len: usize,
    operation_and_plaintext: *const u8,
    operation_and_plaintext_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let mut device = unsafe { device(handle) }?;
        let group_id =
            unsafe { input(group_id, group_id_len, MAX_GROUP_ID_BYTES) }?;
        let payload = unsafe {
            input(
                operation_and_plaintext,
                operation_and_plaintext_len,
                MAX_APPLICATION_BYTES + 28,
            )
        }?;
        if payload.len() <= 28 {
            return Err(YappaMlsError::InvalidInput);
        }
        let outgoing =
            device.stage_outgoing_application(group_id, &payload[..28], &payload[28..])?;
        Ok(YappaMlsResult::success(
            outgoing.epoch,
            encode_outgoing(&outgoing)?,
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_pending_outgoing_applications(
    handle: *mut YappaMlsHandle,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI handle contract.
        let device = unsafe { device(handle) }?;
        Ok(YappaMlsResult::success(
            0,
            encode_outgoing_list(device.pending_outgoing_applications())?,
        ))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn yappa_mls_clear_outgoing_application(
    handle: *mut YappaMlsHandle,
    operation_id: *const u8,
    operation_id_len: usize,
) -> YappaMlsResult {
    invoke(|| {
        // SAFETY: Validated against the ABI contracts.
        let mut device = unsafe { device(handle) }?;
        let operation_id = unsafe { input(operation_id, operation_id_len, 28) }?;
        device.clear_outgoing_application(operation_id)?;
        Ok(YappaMlsResult::success(0, Vec::new()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_rejects_invalid_inputs_without_unwinding() {
        // SAFETY: Null pointers deliberately exercise the ABI validation.
        unsafe {
            assert!(yappa_mls_device_new(ptr::null(), 1).is_null());
            let result = yappa_mls_signature_public_key(ptr::null_mut());
            assert_eq!(result.code, 1);
            assert!(result.buffer.data.is_null());
        }
    }

    #[test]
    fn ffi_owns_and_releases_device_and_result_buffers() {
        let identity = b"server|yuid|device";
        // SAFETY: All pointers refer to live allocations for each call.
        unsafe {
            let handle = yappa_mls_device_new(identity.as_ptr(), identity.len());
            assert!(!handle.is_null());
            let key = yappa_mls_signature_public_key(handle);
            assert_eq!(key.code, 0);
            assert_eq!(key.buffer.len, 32);
            yappa_mls_buffer_free(key.buffer);
            yappa_mls_device_free(handle);
        }
    }
}
