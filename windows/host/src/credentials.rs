use std::{
    env,
    error::Error as StdError,
    fmt, fs,
    fs::OpenOptions,
    io::{self, Write},
    path::{Path, PathBuf},
    process,
    time::{SystemTime, UNIX_EPOCH},
};

use doki_dango_platform_windows::{
    DataProtectionError, protect_for_current_user, unprotect_for_current_user,
};

const CREDENTIAL_MAGIC: &[u8] = b"DOKI-CRED\x01";
const FIREBASE_SERVICE_ACCOUNT_FILE: &str = "firebase-service-account.dpapi";

#[derive(Debug)]
pub enum CredentialStoreError {
    EmptyCredential,
    InvalidFormat,
    Io(io::Error),
    Protection(DataProtectionError),
}

impl fmt::Display for CredentialStoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyCredential => formatter.write_str("credential payload is empty"),
            Self::InvalidFormat => formatter.write_str("credential file format is invalid"),
            Self::Io(error) => write!(formatter, "credential storage failed: {error}"),
            Self::Protection(error) => write!(formatter, "credential protection failed: {error}"),
        }
    }
}

impl StdError for CredentialStoreError {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        match self {
            Self::EmptyCredential | Self::InvalidFormat => None,
            Self::Io(error) => Some(error),
            Self::Protection(error) => Some(error),
        }
    }
}

impl From<io::Error> for CredentialStoreError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<DataProtectionError> for CredentialStoreError {
    fn from(error: DataProtectionError) -> Self {
        Self::Protection(error)
    }
}

pub struct SecretBytes(Vec<u8>);

impl SecretBytes {
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl Drop for SecretBytes {
    fn drop(&mut self) {
        for byte in &mut self.0 {
            unsafe {
                std::ptr::write_volatile(byte, 0);
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct ProtectedCredentialFile {
    path: PathBuf,
}

impl ProtectedCredentialFile {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn firebase_service_account() -> io::Result<Self> {
        let local_app_data = env::var_os("LOCALAPPDATA")
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "LOCALAPPDATA is not set"))?;

        Ok(Self::new(
            PathBuf::from(local_app_data)
                .join("Doki-Dango")
                .join("Host")
                .join("credentials")
                .join(FIREBASE_SERVICE_ACCOUNT_FILE),
        ))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn exists(&self) -> bool {
        self.path.is_file()
    }

    pub fn save(&self, plaintext: &[u8]) -> Result<(), CredentialStoreError> {
        if plaintext.is_empty() {
            return Err(CredentialStoreError::EmptyCredential);
        }

        let encrypted = protect_for_current_user(plaintext)?;
        let mut encoded = Vec::with_capacity(CREDENTIAL_MAGIC.len() + encrypted.len());
        encoded.extend_from_slice(CREDENTIAL_MAGIC);
        encoded.extend_from_slice(&encrypted);

        let parent = self.path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "credential path has no parent")
        })?;
        fs::create_dir_all(parent)?;

        let temporary_path = temporary_path_for(&self.path);
        let write_result = write_new_file(&temporary_path, &encoded);
        if let Err(error) = write_result {
            let _ = fs::remove_file(&temporary_path);
            return Err(error.into());
        }

        if self.path.exists() {
            fs::remove_file(&self.path)?;
        }

        if let Err(error) = fs::rename(&temporary_path, &self.path) {
            let _ = fs::remove_file(&temporary_path);
            return Err(error.into());
        }

        Ok(())
    }

    pub fn load(&self) -> Result<Option<SecretBytes>, CredentialStoreError> {
        let encoded = match fs::read(&self.path) {
            Ok(value) => value,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
        };

        let encrypted = encoded
            .strip_prefix(CREDENTIAL_MAGIC)
            .ok_or(CredentialStoreError::InvalidFormat)?;

        if encrypted.is_empty() {
            return Err(CredentialStoreError::InvalidFormat);
        }

        Ok(Some(SecretBytes(unprotect_for_current_user(encrypted)?)))
    }

    pub fn delete(&self) -> Result<bool, CredentialStoreError> {
        match fs::remove_file(&self.path) {
            Ok(()) => Ok(true),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(error) => Err(error.into()),
        }
    }
}

fn write_new_file(path: &Path, data: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(data)?;
    file.sync_all()
}

fn temporary_path_for(destination: &Path) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();

    let file_name = destination
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("credential");

    destination.with_file_name(format!("{file_name}.tmp-{}-{nonce}", process::id()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_store(name: &str) -> ProtectedCredentialFile {
        let root = env::temp_dir().join(format!(
            "doki-dango-credential-test-{}-{}",
            process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        ProtectedCredentialFile::new(root.join(name))
    }

    #[test]
    fn stores_only_dpapi_protected_bytes() {
        let store = test_store("synthetic.dpapi");
        let secret = b"DOKI-CREDENTIAL-SYNTHETIC-ROUNDTRIP-7F9B";

        store.save(secret).expect("save");
        let encoded = fs::read(store.path()).expect("read encrypted file");

        assert!(encoded.starts_with(CREDENTIAL_MAGIC));
        assert!(encoded.windows(secret.len()).all(|window| window != secret));
        let loaded = store.load().expect("load").expect("credential");
        assert_eq!(loaded.as_bytes(), secret);

        store.delete().expect("delete");
    }

    #[test]
    fn rejects_tampered_ciphertext() {
        let store = test_store("tamper.dpapi");
        let secret = b"DOKI-CREDENTIAL-SYNTHETIC-TAMPER-52C1";

        store.save(secret).expect("save");
        let mut encoded = fs::read(store.path()).expect("read encrypted file");
        let encrypted_offset = CREDENTIAL_MAGIC.len();
        let index = encrypted_offset + (encoded.len() - encrypted_offset) / 2;
        encoded[index] ^= 0xA5;
        fs::write(store.path(), encoded).expect("tamper file");

        assert!(store.load().is_err());

        store.delete().expect("delete");
    }

    #[test]
    fn replaces_existing_credential_without_plaintext_file() {
        let store = test_store("replace.dpapi");
        let first = b"DOKI-CREDENTIAL-SYNTHETIC-FIRST";
        let second = b"DOKI-CREDENTIAL-SYNTHETIC-SECOND";

        store.save(first).expect("save first");
        store.save(second).expect("save second");

        let loaded = store.load().expect("load second").expect("credential");
        assert_eq!(loaded.as_bytes(), second);

        let encoded = fs::read(store.path()).expect("read encrypted file");
        assert!(encoded.windows(first.len()).all(|window| window != first));
        assert!(encoded.windows(second.len()).all(|window| window != second));

        store.delete().expect("delete");
    }
}
