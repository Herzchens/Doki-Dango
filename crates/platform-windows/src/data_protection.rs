use std::{error::Error as StdError, fmt, slice};

use windows::{
    Win32::{
        Foundation::{HLOCAL, LocalFree},
        Security::Cryptography::{
            CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData,
        },
    },
    core::PCWSTR,
};

#[derive(Debug)]
pub enum DataProtectionError {
    InputTooLarge,
    InvalidOutput,
    Windows(windows::core::Error),
}

impl fmt::Display for DataProtectionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InputTooLarge => formatter.write_str("DPAPI input exceeds the supported size"),
            Self::InvalidOutput => {
                formatter.write_str("Windows DPAPI returned an invalid output buffer")
            }
            Self::Windows(error) => write!(formatter, "Windows DPAPI failed: {error}"),
        }
    }
}

impl StdError for DataProtectionError {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        match self {
            Self::InputTooLarge | Self::InvalidOutput => None,
            Self::Windows(error) => Some(error),
        }
    }
}

impl From<windows::core::Error> for DataProtectionError {
    fn from(error: windows::core::Error) -> Self {
        Self::Windows(error)
    }
}

pub fn protect_for_current_user(plaintext: &[u8]) -> Result<Vec<u8>, DataProtectionError> {
    let input = blob_from_slice(plaintext)?;
    let mut output = CRYPT_INTEGER_BLOB::default();

    unsafe {
        CryptProtectData(
            &input,
            PCWSTR::null(),
            None,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )?;
    }

    copy_and_free(output, false)
}

pub fn unprotect_for_current_user(ciphertext: &[u8]) -> Result<Vec<u8>, DataProtectionError> {
    let input = blob_from_slice(ciphertext)?;
    let mut output = CRYPT_INTEGER_BLOB::default();

    unsafe {
        CryptUnprotectData(
            &input,
            None,
            None,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )?;
    }

    copy_and_free(output, true)
}

fn blob_from_slice(data: &[u8]) -> Result<CRYPT_INTEGER_BLOB, DataProtectionError> {
    let length = u32::try_from(data.len()).map_err(|_| DataProtectionError::InputTooLarge)?;

    Ok(CRYPT_INTEGER_BLOB {
        cbData: length,
        pbData: data.as_ptr().cast_mut(),
    })
}

fn copy_and_free(
    blob: CRYPT_INTEGER_BLOB,
    zero_before_free: bool,
) -> Result<Vec<u8>, DataProtectionError> {
    let allocation = LocalAllocation::new(blob, zero_before_free);
    let length =
        usize::try_from(allocation.blob.cbData).map_err(|_| DataProtectionError::InputTooLarge)?;

    if length == 0 {
        return Ok(Vec::new());
    }
    if allocation.blob.pbData.is_null() {
        return Err(DataProtectionError::InvalidOutput);
    }

    let bytes = unsafe { slice::from_raw_parts(allocation.blob.pbData, length) };
    Ok(bytes.to_vec())
}

struct LocalAllocation {
    blob: CRYPT_INTEGER_BLOB,
    zero_before_free: bool,
}

impl LocalAllocation {
    fn new(blob: CRYPT_INTEGER_BLOB, zero_before_free: bool) -> Self {
        Self {
            blob,
            zero_before_free,
        }
    }
}

impl Drop for LocalAllocation {
    fn drop(&mut self) {
        if !self.blob.pbData.is_null() {
            if self.zero_before_free && self.blob.cbData > 0 {
                for offset in 0..self.blob.cbData as usize {
                    unsafe {
                        std::ptr::write_volatile(self.blob.pbData.add(offset), 0);
                    }
                }
            }

            unsafe {
                let _ = LocalFree(Some(HLOCAL(self.blob.pbData.cast())));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_current_user_data() {
        let plaintext = b"DOKI-DPAPI-SYNTHETIC-ROUNDTRIP";
        let protected = protect_for_current_user(plaintext).expect("protect");

        assert_ne!(protected, plaintext);
        assert!(
            protected
                .windows(plaintext.len())
                .all(|window| window != plaintext)
        );

        let unprotected = unprotect_for_current_user(&protected).expect("unprotect");
        assert_eq!(unprotected, plaintext);
    }

    #[test]
    fn tampering_is_rejected() {
        let plaintext = b"DOKI-DPAPI-SYNTHETIC-TAMPER";
        let mut protected = protect_for_current_user(plaintext).expect("protect");
        let index = protected.len() / 2;
        protected[index] ^= 0x5A;

        assert!(unprotect_for_current_user(&protected).is_err());
    }
}
