//! Native RFC 9420 foundation for Yappa's persisted message encryption.
//!
//! Keep this crate's public boundary small and versioned. Flutter must never
//! receive raw MLS private state or ask this layer to export epoch secrets.

use aes_gcm::{
    Aes256Gcm, KeyInit, Nonce,
    aead::{Aead, Payload},
};
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_memory_storage::MemoryStorage;
use openmls_rust_crypto::RustCrypto;
use openmls_traits::{
    OpenMlsProvider,
    types::SignatureScheme,
};
use rand::{RngCore, rngs::OsRng};
use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use thiserror::Error;
use tls_codec::{Deserialize as TlsDeserialize, Serialize as TlsSerialize};
use zeroize::Zeroize;

mod ffi;

/// Version of Yappa's native messaging-E2EE ABI.
pub const YAPPA_MLS_ABI_VERSION: u32 = 4;

/// Exact OpenMLS release reviewed and pinned by this bridge.
pub const OPENMLS_VERSION: &str = "0.8.1";

/// RFC 9420 mandatory-to-implement suite selected for the first Yappa format.
pub const YAPPA_MLS_CIPHERSUITE: Ciphersuite =
    Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

pub(crate) const MAX_IDENTITY_BYTES: usize = 1024;
pub(crate) const MAX_GROUP_ID_BYTES: usize = 1024;
pub(crate) const MAX_WIRE_BYTES: usize = 1024 * 1024;
pub(crate) const MAX_APPLICATION_BYTES: usize = 256 * 1024;
pub(crate) const MAX_STATE_BYTES: usize = 64 * 1024 * 1024;
const MAX_STATE_ENTRIES: usize = 100_000;
const MAX_PENDING_APPLICATIONS: usize = 1_000;
const MAX_PENDING_OUTGOING: usize = 1_000;
const STATE_OUTER_MAGIC: &[u8; 4] = b"YMS1";
const STATE_INNER_MAGIC_V1: &[u8; 8] = b"YMLSST01";
const STATE_INNER_MAGIC_V2: &[u8; 8] = b"YMLSST02";
const STATE_INNER_MAGIC: &[u8; 8] = b"YMLSST03";
const STATE_NONCE_BYTES: usize = 12;
const STATE_TAG_BYTES: usize = 16;
const MAX_ENCRYPTED_STATE_BYTES: usize =
    STATE_OUTER_MAGIC.len() + STATE_NONCE_BYTES + MAX_STATE_BYTES + STATE_TAG_BYTES;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum YappaMlsError {
    #[error("invalid input")]
    InvalidInput,
    #[error("MLS state is missing")]
    MissingState,
    #[error("MLS state conflict")]
    StateConflict,
    #[error("invalid MLS wire message")]
    InvalidWireMessage,
    #[error("unexpected MLS message class")]
    UnexpectedMessageClass,
    #[error("MLS cryptographic operation failed")]
    CryptographicFailure,
}

/// The provider is deliberately owned by Yappa so its storage can later be
/// wrapped and persisted without exporting epoch secrets through the ABI.
#[derive(Debug, Default)]
struct YappaProvider {
    crypto: RustCrypto,
    storage: MemoryStorage,
}

impl YappaProvider {
    fn from_values(values: HashMap<Vec<u8>, Vec<u8>>) -> Self {
        Self {
            crypto: RustCrypto::default(),
            storage: MemoryStorage {
                values: std::sync::RwLock::new(values),
            },
        }
    }
}

impl OpenMlsProvider for YappaProvider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = MemoryStorage;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

#[derive(Debug)]
pub struct PreparedAdd {
    pub commit: Vec<u8>,
    pub welcome: Vec<u8>,
    pub parent_epoch: u64,
    pub accepted_epoch: u64,
}

#[derive(Debug)]
pub struct PreparedCommit {
    pub commit: Vec<u8>,
    pub parent_epoch: u64,
    pub accepted_epoch: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DecryptedApplication {
    pub plaintext: Vec<u8>,
    pub sender_credential: Vec<u8>,
    pub sender_signature_public_key: Vec<u8>,
    pub epoch: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub struct GroupMember {
    pub credential: Vec<u8>,
    pub signature_public_key: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutgoingApplication {
    pub group_id: Vec<u8>,
    pub operation_id: Vec<u8>,
    pub epoch: u64,
    pub plaintext: Vec<u8>,
    pub wire: Vec<u8>,
}

/// One local MLS installation/device.
///
/// The signer and all HPKE/group private material remain inside the provider.
/// The public signature key is exposed only so Flutter can bind it to YUID.
pub struct MlsDevice {
    provider: YappaProvider,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
    pending_applications: HashMap<Vec<u8>, DecryptedApplication>,
    pending_outgoing: HashMap<Vec<u8>, OutgoingApplication>,
}

impl MlsDevice {
    pub fn new(identity: &[u8]) -> Result<Self, YappaMlsError> {
        validate_bounded(identity, MAX_IDENTITY_BYTES)?;
        let provider = YappaProvider::default();
        let signer = SignatureKeyPair::new(SignatureScheme::ED25519)
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        signer
            .store(provider.storage())
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity.to_vec()).into(),
            signature_key: signer.to_public_vec().into(),
        };
        Ok(Self {
            provider,
            signer,
            credential,
            pending_applications: HashMap::new(),
            pending_outgoing: HashMap::new(),
        })
    }

    pub fn signature_public_key(&self) -> &[u8] {
        self.signer.public()
    }

    /// Serializes all private MLS state under a fresh AES-256-GCM nonce.
    ///
    /// `wrapping_key` belongs in the operating-system credential vault.
    /// `context` must canonically bind the server and local device identity.
    pub fn export_encrypted_state(
        &self,
        wrapping_key: &[u8; 32],
        context: &[u8],
    ) -> Result<Vec<u8>, YappaMlsError> {
        validate_bounded(context, MAX_IDENTITY_BYTES)?;
        let identity = self.credential.credential.serialized_content();
        let public_key = self.signer.public();
        let values = self
            .provider
            .storage
            .values
            .read()
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        if values.len() > MAX_STATE_ENTRIES {
            return Err(YappaMlsError::InvalidInput);
        }
        let mut entries = values.iter().collect::<Vec<_>>();
        entries.sort_unstable_by(|(left, _), (right, _)| left.cmp(right));

        let mut plaintext = Vec::new();
        plaintext.extend_from_slice(STATE_INNER_MAGIC);
        write_bytes(&mut plaintext, identity)?;
        write_bytes(&mut plaintext, public_key)?;
        write_u32(&mut plaintext, entries.len())?;
        for (key, value) in entries {
            write_bytes(&mut plaintext, key)?;
            write_bytes(&mut plaintext, value)?;
            if plaintext.len() > MAX_STATE_BYTES {
                plaintext.zeroize();
                return Err(YappaMlsError::InvalidInput);
            }
        }
        if self.pending_applications.len() > MAX_PENDING_APPLICATIONS {
            plaintext.zeroize();
            return Err(YappaMlsError::InvalidInput);
        }
        let mut pending = self.pending_applications.iter().collect::<Vec<_>>();
        pending.sort_unstable_by(|(left, _), (right, _)| left.cmp(right));
        write_u32(&mut plaintext, pending.len())?;
        for (key, application) in pending {
            write_bytes(&mut plaintext, key)?;
            plaintext.extend_from_slice(&application.epoch.to_be_bytes());
            write_bytes(&mut plaintext, &application.sender_credential)?;
            write_bytes(
                &mut plaintext,
                &application.sender_signature_public_key,
            )?;
            write_bytes(&mut plaintext, &application.plaintext)?;
            if plaintext.len() > MAX_STATE_BYTES {
                plaintext.zeroize();
                return Err(YappaMlsError::InvalidInput);
            }
        }
        if self.pending_outgoing.len() > MAX_PENDING_OUTGOING {
            plaintext.zeroize();
            return Err(YappaMlsError::InvalidInput);
        }
        let mut outgoing = self.pending_outgoing.values().collect::<Vec<_>>();
        outgoing.sort_unstable_by(|left, right| {
            left.operation_id.cmp(&right.operation_id)
        });
        write_u32(&mut plaintext, outgoing.len())?;
        for application in outgoing {
            write_bytes(&mut plaintext, &application.group_id)?;
            write_bytes(&mut plaintext, &application.operation_id)?;
            plaintext.extend_from_slice(&application.epoch.to_be_bytes());
            write_bytes(&mut plaintext, &application.plaintext)?;
            write_bytes(&mut plaintext, &application.wire)?;
            if plaintext.len() > MAX_STATE_BYTES {
                plaintext.zeroize();
                return Err(YappaMlsError::InvalidInput);
            }
        }

        let mut nonce_bytes = [0u8; STATE_NONCE_BYTES];
        OsRng.fill_bytes(&mut nonce_bytes);
        let cipher = Aes256Gcm::new_from_slice(wrapping_key)
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        let aad = state_aad(context)?;
        let encrypted = cipher
            .encrypt(
                Nonce::from_slice(&nonce_bytes),
                Payload {
                    msg: &plaintext,
                    aad: &aad,
                },
            )
            .map_err(|_| YappaMlsError::CryptographicFailure);
        plaintext.zeroize();
        let encrypted = encrypted?;
        let mut output = Vec::with_capacity(
            STATE_OUTER_MAGIC.len() + STATE_NONCE_BYTES + encrypted.len(),
        );
        output.extend_from_slice(STATE_OUTER_MAGIC);
        output.extend_from_slice(&nonce_bytes);
        output.extend_from_slice(&encrypted);
        Ok(output)
    }

    pub fn import_encrypted_state(
        wrapping_key: &[u8; 32],
        context: &[u8],
        encrypted: &[u8],
    ) -> Result<Self, YappaMlsError> {
        validate_bounded(context, MAX_IDENTITY_BYTES)?;
        if encrypted.len() <= STATE_OUTER_MAGIC.len() + STATE_NONCE_BYTES
            || encrypted.len() > MAX_ENCRYPTED_STATE_BYTES
            || !encrypted.starts_with(STATE_OUTER_MAGIC)
        {
            return Err(YappaMlsError::InvalidInput);
        }
        let nonce_start = STATE_OUTER_MAGIC.len();
        let ciphertext_start = nonce_start + STATE_NONCE_BYTES;
        let cipher = Aes256Gcm::new_from_slice(wrapping_key)
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        let aad = state_aad(context)?;
        let mut plaintext = cipher
            .decrypt(
                Nonce::from_slice(&encrypted[nonce_start..ciphertext_start]),
                Payload {
                    msg: &encrypted[ciphertext_start..],
                    aad: &aad,
                },
            )
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        let decoded = decode_state(&plaintext);
        plaintext.zeroize();
        let (
            identity,
            public_key,
            values,
            pending_applications,
            pending_outgoing,
        ) = decoded?;
        let provider = YappaProvider::from_values(values);
        let signer = SignatureKeyPair::read(
            provider.storage(),
            &public_key,
            SignatureScheme::ED25519,
        )
        .ok_or(YappaMlsError::CryptographicFailure)?;
        if signer.public() != public_key {
            return Err(YappaMlsError::CryptographicFailure);
        }
        let credential = CredentialWithKey {
            credential: BasicCredential::new(identity).into(),
            signature_key: public_key.into(),
        };
        Ok(Self {
            provider,
            signer,
            credential,
            pending_applications,
            pending_outgoing,
        })
    }

    pub fn generate_key_package(&self) -> Result<Vec<u8>, YappaMlsError> {
        let bundle = KeyPackage::builder()
            .key_package_extensions(Extensions::empty())
            .build(
                YAPPA_MLS_CIPHERSUITE,
                &self.provider,
                &self.signer,
                self.credential.clone(),
            )
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        bundle
            .key_package()
            .tls_serialize_detached()
            .map_err(|_| YappaMlsError::CryptographicFailure)
    }

    pub fn create_group(&self, group_id: &[u8]) -> Result<u64, YappaMlsError> {
        validate_bounded(group_id, MAX_GROUP_ID_BYTES)?;
        let group_id = GroupId::from_slice(group_id);
        if MlsGroup::load(self.provider.storage(), &group_id)
            .map_err(|_| YappaMlsError::CryptographicFailure)?
            .is_some()
        {
            return Err(YappaMlsError::StateConflict);
        }
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(YAPPA_MLS_CIPHERSUITE)
            .use_ratchet_tree_extension(true)
            .build();
        let group = MlsGroup::new_with_group_id(
            &self.provider,
            &self.signer,
            &config,
            group_id,
            self.credential.clone(),
        )
        .map_err(|_| YappaMlsError::CryptographicFailure)?;
        Ok(group.epoch().as_u64())
    }

    pub fn prepare_add(
        &self,
        group_id: &[u8],
        key_package_wire: &[u8],
    ) -> Result<PreparedAdd, YappaMlsError> {
        validate_bounded(group_id, MAX_GROUP_ID_BYTES)?;
        validate_bounded(key_package_wire, MAX_WIRE_BYTES)?;
        let mut group = self.load_group(group_id)?;
        if group.pending_commit().is_some() {
            return Err(YappaMlsError::StateConflict);
        }
        let parent_epoch = group.epoch().as_u64();
        let key_package = KeyPackageIn::tls_deserialize_exact(key_package_wire)
            .map_err(|_| YappaMlsError::InvalidWireMessage)?
            .validate(self.provider.crypto(), ProtocolVersion::Mls10)
            .map_err(|_| YappaMlsError::InvalidWireMessage)?;
        if key_package.ciphersuite() != YAPPA_MLS_CIPHERSUITE {
            return Err(YappaMlsError::InvalidWireMessage);
        }
        let (commit, welcome, _) = group
            .add_members(
                &self.provider,
                &self.signer,
                core::slice::from_ref(&key_package),
            )
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        Ok(PreparedAdd {
            commit: commit
                .tls_serialize_detached()
                .map_err(|_| YappaMlsError::CryptographicFailure)?,
            welcome: MlsMessageOut::from(welcome)
                .tls_serialize_detached()
                .map_err(|_| YappaMlsError::CryptographicFailure)?,
            parent_epoch,
            accepted_epoch: parent_epoch + 1,
        })
    }

    /// Stages a self-update. Callers must submit the returned commit through
    /// the ordered delivery service before accepting or rejecting it.
    pub fn prepare_self_update(
        &self,
        group_id: &[u8],
    ) -> Result<PreparedCommit, YappaMlsError> {
        let mut group = self.load_group(group_id)?;
        if group.pending_commit().is_some() {
            return Err(YappaMlsError::StateConflict);
        }
        let parent_epoch = group.epoch().as_u64();
        let bundle = group
            .self_update(
                &self.provider,
                &self.signer,
                LeafNodeParameters::default(),
            )
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        let (commit, _, _) = bundle.into_contents();
        Ok(PreparedCommit {
            commit: commit
                .tls_serialize_detached()
                .map_err(|_| YappaMlsError::CryptographicFailure)?,
            parent_epoch,
            accepted_epoch: parent_epoch + 1,
        })
    }

    /// Stages removal of exactly one credential. Matching by authenticated
    /// credential avoids exposing or trusting a caller-supplied tree index.
    pub fn prepare_remove(
        &self,
        group_id: &[u8],
        member_credential: &[u8],
    ) -> Result<PreparedCommit, YappaMlsError> {
        validate_bounded(member_credential, MAX_IDENTITY_BYTES)?;
        let mut group = self.load_group(group_id)?;
        if group.pending_commit().is_some() {
            return Err(YappaMlsError::StateConflict);
        }
        let matches = group
            .members()
            .filter(|member| {
                member.credential.serialized_content() == member_credential
            })
            .map(|member| member.index)
            .collect::<Vec<_>>();
        let target = match matches.as_slice() {
            [] => return Err(YappaMlsError::MissingState),
            [target] => *target,
            _ => return Err(YappaMlsError::StateConflict),
        };
        let parent_epoch = group.epoch().as_u64();
        let (commit, _, _) = group
            .remove_members(&self.provider, &self.signer, &[target])
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        Ok(PreparedCommit {
            commit: commit
                .tls_serialize_detached()
                .map_err(|_| YappaMlsError::CryptographicFailure)?,
            parent_epoch,
            accepted_epoch: parent_epoch + 1,
        })
    }

    pub fn accept_pending_commit(&self, group_id: &[u8]) -> Result<u64, YappaMlsError> {
        let mut group = self.load_group(group_id)?;
        if group.pending_commit().is_none() {
            return Err(YappaMlsError::MissingState);
        }
        group
            .merge_pending_commit(&self.provider)
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        Ok(group.epoch().as_u64())
    }

    pub fn reject_pending_commit(&self, group_id: &[u8]) -> Result<u64, YappaMlsError> {
        let mut group = self.load_group(group_id)?;
        if group.pending_commit().is_none() {
            return Err(YappaMlsError::MissingState);
        }
        group
            .clear_pending_commit(self.provider.storage())
            .map_err(|_| YappaMlsError::CryptographicFailure)?;
        Ok(group.epoch().as_u64())
    }

    pub fn join_from_welcome(
        &self,
        expected_group_id: &[u8],
        welcome_wire: &[u8],
    ) -> Result<u64, YappaMlsError> {
        validate_bounded(expected_group_id, MAX_GROUP_ID_BYTES)?;
        validate_bounded(welcome_wire, MAX_WIRE_BYTES)?;
        let expected = GroupId::from_slice(expected_group_id);
        if MlsGroup::load(self.provider.storage(), &expected)
            .map_err(|_| YappaMlsError::CryptographicFailure)?
            .is_some()
        {
            return Err(YappaMlsError::StateConflict);
        }
        let welcome = match MlsMessageIn::tls_deserialize_exact(welcome_wire)
            .map_err(|_| YappaMlsError::InvalidWireMessage)?
            .extract()
        {
            MlsMessageBodyIn::Welcome(welcome) => welcome,
            _ => return Err(YappaMlsError::UnexpectedMessageClass),
        };
        let config = MlsGroupJoinConfig::builder()
            .use_ratchet_tree_extension(true)
            .build();
        let group = StagedWelcome::new_from_welcome(
            &self.provider,
            &config,
            welcome,
            None,
        )
        .map_err(|_| YappaMlsError::CryptographicFailure)?
        .into_group(&self.provider)
        .map_err(|_| YappaMlsError::CryptographicFailure)?;
        if group.group_id() != &expected {
            let mut group = group;
            let _ = group.delete(self.provider.storage());
            return Err(YappaMlsError::InvalidWireMessage);
        }
        Ok(group.epoch().as_u64())
    }

    pub fn process_commit(
        &self,
        group_id: &[u8],
        commit_wire: &[u8],
    ) -> Result<u64, YappaMlsError> {
        validate_bounded(commit_wire, MAX_WIRE_BYTES)?;
        let mut group = self.load_group(group_id)?;
        let protocol = protocol_message(commit_wire)?;
        let processed = contain_untrusted_mls(|| {
            group.process_message(&self.provider, protocol)
        })?;
        match processed.into_content() {
            ProcessedMessageContent::StagedCommitMessage(commit) => {
                group
                    .merge_staged_commit(&self.provider, *commit)
                    .map_err(|_| YappaMlsError::CryptographicFailure)?;
                Ok(group.epoch().as_u64())
            }
            _ => Err(YappaMlsError::UnexpectedMessageClass),
        }
    }

    /// Returns the authenticated leaf credentials and signature keys in a
    /// canonical order suitable for comparison with YUID-authorized devices.
    pub fn group_members(
        &self,
        group_id: &[u8],
    ) -> Result<Vec<GroupMember>, YappaMlsError> {
        let group = self.load_group(group_id)?;
        let mut members = group
            .members()
            .map(|member| GroupMember {
                credential: member.credential.serialized_content().to_vec(),
                signature_public_key: member.signature_key,
            })
            .collect::<Vec<_>>();
        if members.is_empty()
            || members.len() > 10_000
            || members.iter().any(|member| {
                member.credential.is_empty()
                    || member.credential.len() > MAX_IDENTITY_BYTES
                    || member.signature_public_key.len() != 32
            })
        {
            return Err(YappaMlsError::CryptographicFailure);
        }
        members.sort_unstable_by(|left, right| {
            left.credential
                .cmp(&right.credential)
                .then_with(|| left.signature_public_key.cmp(&right.signature_public_key))
        });
        Ok(members)
    }

    pub fn encrypt_application(
        &self,
        group_id: &[u8],
        plaintext: &[u8],
    ) -> Result<Vec<u8>, YappaMlsError> {
        validate_bounded(plaintext, MAX_APPLICATION_BYTES)?;
        let mut group = self.load_group(group_id)?;
        if group.pending_commit().is_some() {
            return Err(YappaMlsError::StateConflict);
        }
        group
            .create_message(&self.provider, &self.signer, plaintext)
            .map_err(|_| YappaMlsError::CryptographicFailure)?
            .tls_serialize_detached()
            .map_err(|_| YappaMlsError::CryptographicFailure)
    }

    pub fn decrypt_application(
        &self,
        group_id: &[u8],
        wire: &[u8],
    ) -> Result<DecryptedApplication, YappaMlsError> {
        validate_bounded(wire, MAX_WIRE_BYTES)?;
        let mut group = self.load_group(group_id)?;
        let epoch = group.epoch().as_u64();
        let protocol = protocol_message(wire)?;
        let processed = contain_untrusted_mls(|| {
            group.process_message(&self.provider, protocol)
        })?;
        let sender_credential = processed.credential().serialized_content().to_vec();
        let sender_index = match processed.sender() {
            Sender::Member(index) => *index,
            _ => return Err(YappaMlsError::UnexpectedMessageClass),
        };
        let sender_signature_public_key = group
            .members()
            .find(|member| member.index == sender_index)
            .map(|member| member.signature_key)
            .ok_or(YappaMlsError::CryptographicFailure)?;
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) => {
                let mut plaintext = message.into_bytes();
                if plaintext.len() > MAX_APPLICATION_BYTES {
                    plaintext.zeroize();
                    return Err(YappaMlsError::InvalidWireMessage);
                }
                Ok(DecryptedApplication {
                    plaintext,
                    sender_credential,
                    sender_signature_public_key,
                    epoch,
                })
            }
            _ => Err(YappaMlsError::UnexpectedMessageClass),
        }
    }

    /// Stores the authenticated result beside the MLS ratchet update so a
    /// crash cannot make a message unreplayable before Flutter persists it.
    pub fn stage_application(
        &mut self,
        group_id: &[u8],
        server_sequence: u64,
        wire: &[u8],
    ) -> Result<DecryptedApplication, YappaMlsError> {
        if server_sequence == 0 {
            return Err(YappaMlsError::InvalidInput);
        }
        let key = application_receipt_key(group_id, server_sequence)?;
        if let Some(existing) = self.pending_applications.get(&key) {
            return Ok(existing.clone());
        }
        if self.pending_applications.len() >= MAX_PENDING_APPLICATIONS {
            return Err(YappaMlsError::StateConflict);
        }
        let application = self.decrypt_application(group_id, wire)?;
        self.pending_applications.insert(key, application.clone());
        Ok(application)
    }

    pub fn clear_staged_application(
        &mut self,
        group_id: &[u8],
        server_sequence: u64,
    ) -> Result<u64, YappaMlsError> {
        let key = application_receipt_key(group_id, server_sequence)?;
        self.pending_applications.remove(&key);
        Ok(server_sequence)
    }

    pub fn stage_outgoing_application(
        &mut self,
        group_id: &[u8],
        operation_id: &[u8],
        plaintext: &[u8],
    ) -> Result<OutgoingApplication, YappaMlsError> {
        validate_operation_id(operation_id)?;
        validate_bounded(plaintext, MAX_APPLICATION_BYTES)?;
        if let Some(existing) = self.pending_outgoing.get(operation_id) {
            if existing.group_id != group_id || existing.plaintext != plaintext {
                return Err(YappaMlsError::StateConflict);
            }
            return Ok(existing.clone());
        }
        if self.pending_outgoing.len() >= MAX_PENDING_OUTGOING {
            return Err(YappaMlsError::StateConflict);
        }
        let epoch = self.epoch(group_id)?;
        let wire = self.encrypt_application(group_id, plaintext)?;
        let application = OutgoingApplication {
            group_id: group_id.to_vec(),
            operation_id: operation_id.to_vec(),
            epoch,
            plaintext: plaintext.to_vec(),
            wire,
        };
        self.pending_outgoing
            .insert(operation_id.to_vec(), application.clone());
        Ok(application)
    }

    pub fn pending_outgoing_applications(
        &self,
    ) -> Vec<OutgoingApplication> {
        let mut values = self.pending_outgoing.values().cloned().collect::<Vec<_>>();
        values.sort_unstable_by(|left, right| {
            left.operation_id.cmp(&right.operation_id)
        });
        values
    }

    pub fn clear_outgoing_application(
        &mut self,
        operation_id: &[u8],
    ) -> Result<(), YappaMlsError> {
        validate_operation_id(operation_id)?;
        self.pending_outgoing.remove(operation_id);
        Ok(())
    }

    pub fn epoch(&self, group_id: &[u8]) -> Result<u64, YappaMlsError> {
        Ok(self.load_group(group_id)?.epoch().as_u64())
    }

    fn load_group(&self, group_id: &[u8]) -> Result<MlsGroup, YappaMlsError> {
        validate_bounded(group_id, MAX_GROUP_ID_BYTES)?;
        MlsGroup::load(
            self.provider.storage(),
            &GroupId::from_slice(group_id),
        )
        .map_err(|_| YappaMlsError::CryptographicFailure)?
        .ok_or(YappaMlsError::MissingState)
    }
}

fn protocol_message(wire: &[u8]) -> Result<ProtocolMessage, YappaMlsError> {
    MlsMessageIn::tls_deserialize_exact(wire)
        .map_err(|_| YappaMlsError::InvalidWireMessage)?
        .try_into_protocol_message()
        .map_err(|_| YappaMlsError::UnexpectedMessageClass)
}

fn contain_untrusted_mls<T, E>(
    operation: impl FnOnce() -> Result<T, E>,
) -> Result<T, YappaMlsError> {
    catch_unwind(AssertUnwindSafe(operation))
        .map_err(|_| YappaMlsError::CryptographicFailure)?
        .map_err(|_| YappaMlsError::CryptographicFailure)
}

fn validate_bounded(value: &[u8], max: usize) -> Result<(), YappaMlsError> {
    if value.is_empty() || value.len() > max {
        return Err(YappaMlsError::InvalidInput);
    }
    Ok(())
}

fn validate_operation_id(value: &[u8]) -> Result<(), YappaMlsError> {
    if value.len() != 28
        || !value.starts_with(b"mlsop_")
        || !value[6..]
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'-')
    {
        return Err(YappaMlsError::InvalidInput);
    }
    Ok(())
}

fn state_aad(context: &[u8]) -> Result<Vec<u8>, YappaMlsError> {
    let mut aad = b"yappa-mls-state-v1".to_vec();
    write_bytes(&mut aad, context)?;
    Ok(aad)
}

fn application_receipt_key(
    group_id: &[u8],
    server_sequence: u64,
) -> Result<Vec<u8>, YappaMlsError> {
    validate_bounded(group_id, MAX_GROUP_ID_BYTES)?;
    let mut key = Vec::with_capacity(4 + group_id.len() + 8);
    write_bytes(&mut key, group_id)?;
    key.extend_from_slice(&server_sequence.to_be_bytes());
    Ok(key)
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

fn read_u32(input: &[u8], cursor: &mut usize) -> Result<usize, YappaMlsError> {
    let end = cursor
        .checked_add(4)
        .filter(|end| *end <= input.len())
        .ok_or(YappaMlsError::InvalidWireMessage)?;
    let value = u32::from_be_bytes(
        input[*cursor..end]
            .try_into()
            .map_err(|_| YappaMlsError::InvalidWireMessage)?,
    ) as usize;
    *cursor = end;
    Ok(value)
}

fn read_bytes(
    input: &[u8],
    cursor: &mut usize,
    max: usize,
) -> Result<Vec<u8>, YappaMlsError> {
    let length = read_u32(input, cursor)?;
    if length > max {
        return Err(YappaMlsError::InvalidWireMessage);
    }
    let end = cursor
        .checked_add(length)
        .filter(|end| *end <= input.len())
        .ok_or(YappaMlsError::InvalidWireMessage)?;
    let value = input[*cursor..end].to_vec();
    *cursor = end;
    Ok(value)
}

type StateValues = HashMap<Vec<u8>, Vec<u8>>;
type PendingApplications = HashMap<Vec<u8>, DecryptedApplication>;
type PendingOutgoing = HashMap<Vec<u8>, OutgoingApplication>;

fn decode_state(
    plaintext: &[u8],
) -> Result<
    (
        Vec<u8>,
        Vec<u8>,
        StateValues,
        PendingApplications,
        PendingOutgoing,
    ),
    YappaMlsError,
> {
    let version = if plaintext.starts_with(STATE_INNER_MAGIC) {
        3
    } else if plaintext.starts_with(STATE_INNER_MAGIC_V2) {
        2
    } else if plaintext.starts_with(STATE_INNER_MAGIC_V1) {
        1
    } else {
        return Err(YappaMlsError::InvalidWireMessage);
    };
    let mut cursor = STATE_INNER_MAGIC.len();
    let identity = read_bytes(plaintext, &mut cursor, MAX_IDENTITY_BYTES)?;
    validate_bounded(&identity, MAX_IDENTITY_BYTES)?;
    let public_key = read_bytes(plaintext, &mut cursor, 128)?;
    if public_key.len() != 32 {
        return Err(YappaMlsError::InvalidWireMessage);
    }
    let count = read_u32(plaintext, &mut cursor)?;
    if count > MAX_STATE_ENTRIES {
        return Err(YappaMlsError::InvalidWireMessage);
    }
    let mut values = HashMap::with_capacity(count);
    for _ in 0..count {
        let key = read_bytes(plaintext, &mut cursor, MAX_STATE_BYTES)?;
        let value = read_bytes(plaintext, &mut cursor, MAX_STATE_BYTES)?;
        if key.is_empty() || values.insert(key, value).is_some() {
            return Err(YappaMlsError::InvalidWireMessage);
        }
    }
    let mut pending = HashMap::new();
    if version >= 2 {
        let pending_count = read_u32(plaintext, &mut cursor)?;
        if pending_count > MAX_PENDING_APPLICATIONS {
            return Err(YappaMlsError::InvalidWireMessage);
        }
        for _ in 0..pending_count {
            let key =
                read_bytes(plaintext, &mut cursor, MAX_GROUP_ID_BYTES + 12)?;
            let epoch_end = cursor
                .checked_add(8)
                .filter(|end| *end <= plaintext.len())
                .ok_or(YappaMlsError::InvalidWireMessage)?;
            let epoch = u64::from_be_bytes(
                plaintext[cursor..epoch_end]
                    .try_into()
                    .map_err(|_| YappaMlsError::InvalidWireMessage)?,
            );
            cursor = epoch_end;
            let sender_credential =
                read_bytes(plaintext, &mut cursor, MAX_IDENTITY_BYTES)?;
            let sender_signature_public_key =
                read_bytes(plaintext, &mut cursor, 32)?;
            let application_plaintext =
                read_bytes(plaintext, &mut cursor, MAX_APPLICATION_BYTES)?;
            if key.is_empty()
                || sender_credential.is_empty()
                || sender_signature_public_key.len() != 32
                || pending
                    .insert(
                        key,
                        DecryptedApplication {
                            plaintext: application_plaintext,
                            sender_credential,
                            sender_signature_public_key,
                            epoch,
                        },
                    )
                    .is_some()
            {
                return Err(YappaMlsError::InvalidWireMessage);
            }
        }
    }
    let mut outgoing = HashMap::new();
    if version >= 3 {
        let outgoing_count = read_u32(plaintext, &mut cursor)?;
        if outgoing_count > MAX_PENDING_OUTGOING {
            return Err(YappaMlsError::InvalidWireMessage);
        }
        for _ in 0..outgoing_count {
            let group_id =
                read_bytes(plaintext, &mut cursor, MAX_GROUP_ID_BYTES)?;
            let operation_id = read_bytes(plaintext, &mut cursor, 28)?;
            validate_bounded(&group_id, MAX_GROUP_ID_BYTES)?;
            validate_operation_id(&operation_id)?;
            let epoch_end = cursor
                .checked_add(8)
                .filter(|end| *end <= plaintext.len())
                .ok_or(YappaMlsError::InvalidWireMessage)?;
            let epoch = u64::from_be_bytes(
                plaintext[cursor..epoch_end]
                    .try_into()
                    .map_err(|_| YappaMlsError::InvalidWireMessage)?,
            );
            cursor = epoch_end;
            let application_plaintext =
                read_bytes(plaintext, &mut cursor, MAX_APPLICATION_BYTES)?;
            let wire = read_bytes(plaintext, &mut cursor, MAX_WIRE_BYTES)?;
            if application_plaintext.is_empty()
                || wire.is_empty()
                || outgoing
                    .insert(
                        operation_id.clone(),
                        OutgoingApplication {
                            group_id,
                            operation_id,
                            epoch,
                            plaintext: application_plaintext,
                            wire,
                        },
                    )
                    .is_some()
            {
                return Err(YappaMlsError::InvalidWireMessage);
            }
        }
    }
    if cursor != plaintext.len() {
        return Err(YappaMlsError::InvalidWireMessage);
    }
    Ok((identity, public_key, values, pending, outgoing))
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls_traits::{OpenMlsProvider, crypto::OpenMlsCrypto};

    fn device(name: &str) -> MlsDevice {
        MlsDevice::new(name.as_bytes()).unwrap()
    }

    #[test]
    fn pinned_provider_supports_yappa_ciphersuite() {
        let provider = YappaProvider::default();
        let supported = provider.crypto().supported_ciphersuites();

        assert_eq!(OPENMLS_VERSION, "0.8.1");
        assert_eq!(YAPPA_MLS_ABI_VERSION, 4);
        assert!(supported.contains(&YAPPA_MLS_CIPHERSUITE));
    }

    #[test]
    fn two_devices_join_and_exchange_private_application_messages() {
        let alice = device("server|alice-yuid|alice-device");
        let bob = device("server|bob-yuid|bob-device");
        let group_id = b"yappa-text-v1|server|42";

        assert_eq!(alice.create_group(group_id).unwrap(), 0);
        let bob_key_package = bob.generate_key_package().unwrap();
        let prepared = alice.prepare_add(group_id, &bob_key_package).unwrap();
        assert_eq!(prepared.parent_epoch, 0);
        assert_eq!(prepared.accepted_epoch, 1);
        assert_eq!(alice.epoch(group_id).unwrap(), 0);

        assert_eq!(alice.accept_pending_commit(group_id).unwrap(), 1);
        assert_eq!(bob.join_from_welcome(group_id, &prepared.welcome).unwrap(), 1);

        let ciphertext = alice
            .encrypt_application(group_id, b"private message")
            .unwrap();
        assert!(!ciphertext.windows(15).any(|part| part == b"private message"));
        let decrypted = bob.decrypt_application(group_id, &ciphertext).unwrap();
        assert_eq!(decrypted.plaintext, b"private message");
        assert_eq!(
            decrypted.sender_credential,
            b"server|alice-yuid|alice-device"
        );
        assert_eq!(
            decrypted.sender_signature_public_key,
            alice.signature_public_key()
        );
        assert_eq!(decrypted.epoch, 1);
    }

    #[test]
    fn staged_application_receipt_survives_restart_until_cleared() {
        let alice = device("server|alice-yuid|alice-device");
        let mut bob = device("server|bob-yuid|bob-device");
        let group_id = b"yappa-text-v1|server|receipt";
        alice.create_group(group_id).unwrap();
        let add = alice
            .prepare_add(group_id, &bob.generate_key_package().unwrap())
            .unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        bob.join_from_welcome(group_id, &add.welcome).unwrap();
        let wire = alice
            .encrypt_application(group_id, b"durable event")
            .unwrap();
        let first = bob.stage_application(group_id, 9, &wire).unwrap();
        assert_eq!(first.plaintext, b"durable event");

        let key = [41u8; 32];
        let state = bob
            .export_encrypted_state(&key, b"receipt-context")
            .unwrap();
        let mut restored =
            MlsDevice::import_encrypted_state(&key, b"receipt-context", &state)
                .unwrap();
        let replay = restored.stage_application(group_id, 9, &wire).unwrap();
        assert_eq!(replay, first);
        assert_eq!(
            restored.clear_staged_application(group_id, 9).unwrap(),
            9
        );
        assert!(restored.stage_application(group_id, 9, &wire).is_err());
    }

    #[test]
    fn outgoing_application_reuses_exact_ciphertext_across_restart() {
        let mut alice = device("server|alice-yuid|outgoing-device");
        let group_id = b"yappa-text-v1|server|outgoing";
        let operation_id = b"mlsop_abcdefghijklmnopqrstuv";
        alice.create_group(group_id).unwrap();
        let first = alice
            .stage_outgoing_application(
                group_id,
                operation_id,
                b"{\"protocol\":\"yappa-message-v1\"}",
            )
            .unwrap();
        let repeated = alice
            .stage_outgoing_application(
                group_id,
                operation_id,
                b"{\"protocol\":\"yappa-message-v1\"}",
            )
            .unwrap();
        assert_eq!(repeated, first);
        let key = [29u8; 32];
        let state = alice
            .export_encrypted_state(&key, b"outgoing-context")
            .unwrap();
        let mut restored =
            MlsDevice::import_encrypted_state(&key, b"outgoing-context", &state)
                .unwrap();
        assert_eq!(
            restored.pending_outgoing_applications(),
            vec![first.clone()]
        );
        assert_eq!(
            restored
                .stage_outgoing_application(
                    group_id,
                    operation_id,
                    b"{\"protocol\":\"yappa-message-v1\"}",
                )
                .unwrap(),
            first
        );
        restored.clear_outgoing_application(operation_id).unwrap();
        assert!(restored.pending_outgoing_applications().is_empty());
    }

    #[test]
    fn version_two_state_imports_legacy_version_one_plaintext() {
        let alice = device("server|alice-yuid|legacy-device");
        let group_id = b"yappa-text-v1|server|legacy";
        alice.create_group(group_id).unwrap();
        let key = [17u8; 32];
        let context = b"legacy-context";
        let values = alice.provider.storage.values.read().unwrap();
        let mut entries = values.iter().collect::<Vec<_>>();
        entries.sort_unstable_by(|(left, _), (right, _)| left.cmp(right));
        let mut plaintext = STATE_INNER_MAGIC_V1.to_vec();
        write_bytes(
            &mut plaintext,
            alice.credential.credential.serialized_content(),
        )
        .unwrap();
        write_bytes(&mut plaintext, alice.signer.public()).unwrap();
        write_u32(&mut plaintext, entries.len()).unwrap();
        for (entry_key, value) in entries {
            write_bytes(&mut plaintext, entry_key).unwrap();
            write_bytes(&mut plaintext, value).unwrap();
        }
        let nonce = [3u8; STATE_NONCE_BYTES];
        let encrypted = Aes256Gcm::new_from_slice(&key)
            .unwrap()
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &plaintext,
                    aad: &state_aad(context).unwrap(),
                },
            )
            .unwrap();
        plaintext.zeroize();
        let mut legacy = STATE_OUTER_MAGIC.to_vec();
        legacy.extend_from_slice(&nonce);
        legacy.extend_from_slice(&encrypted);

        let restored =
            MlsDevice::import_encrypted_state(&key, context, &legacy).unwrap();
        assert_eq!(restored.epoch(group_id).unwrap(), 0);
        assert!(restored.pending_applications.is_empty());
    }

    #[test]
    fn rejected_commit_does_not_advance_epoch_or_add_member() {
        let alice = device("alice");
        let bob = device("bob");
        let group_id = b"yappa-text-v1|server|43";
        alice.create_group(group_id).unwrap();

        let prepared = alice
            .prepare_add(group_id, &bob.generate_key_package().unwrap())
            .unwrap();
        assert!(!prepared.commit.is_empty());
        assert_eq!(alice.reject_pending_commit(group_id).unwrap(), 0);
        assert_eq!(alice.epoch(group_id).unwrap(), 0);
        assert_eq!(
            alice.accept_pending_commit(group_id),
            Err(YappaMlsError::MissingState)
        );
    }

    #[test]
    fn self_update_advances_all_online_members() {
        let alice = device("alice");
        let bob = device("bob");
        let group_id = b"yappa-text-v1|server|self-update";
        alice.create_group(group_id).unwrap();
        let add = alice
            .prepare_add(group_id, &bob.generate_key_package().unwrap())
            .unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        bob.join_from_welcome(group_id, &add.welcome).unwrap();

        let update = alice.prepare_self_update(group_id).unwrap();
        assert_eq!(update.parent_epoch, 1);
        assert_eq!(update.accepted_epoch, 2);
        assert_eq!(bob.process_commit(group_id, &update.commit).unwrap(), 2);
        assert_eq!(alice.accept_pending_commit(group_id).unwrap(), 2);

        let wire = bob.encrypt_application(group_id, b"after update").unwrap();
        assert_eq!(
            alice
                .decrypt_application(group_id, &wire)
                .unwrap()
                .plaintext,
            b"after update"
        );
    }

    #[test]
    fn removed_member_cannot_decrypt_future_messages() {
        let alice = device("alice");
        let bob = device("bob");
        let group_id = b"yappa-text-v1|server|remove";
        alice.create_group(group_id).unwrap();
        let add = alice
            .prepare_add(group_id, &bob.generate_key_package().unwrap())
            .unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        bob.join_from_welcome(group_id, &add.welcome).unwrap();

        let removal = alice.prepare_remove(group_id, b"bob").unwrap();
        assert_eq!(alice.accept_pending_commit(group_id).unwrap(), 2);
        assert_eq!(bob.process_commit(group_id, &removal.commit).unwrap(), 2);
        let future = alice
            .encrypt_application(group_id, b"future secret")
            .unwrap();
        assert!(bob.decrypt_application(group_id, &future).is_err());
        assert!(bob.encrypt_application(group_id, b"removed sender").is_err());
    }

    #[test]
    fn newly_added_member_cannot_decrypt_prior_history() {
        let alice = device("alice");
        let bob = device("bob");
        let group_id = b"yappa-text-v1|server|history";
        alice.create_group(group_id).unwrap();
        let prior = alice
            .encrypt_application(group_id, b"before bob")
            .unwrap();

        let add = alice
            .prepare_add(group_id, &bob.generate_key_package().unwrap())
            .unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        bob.join_from_welcome(group_id, &add.welcome).unwrap();

        assert!(bob.decrypt_application(group_id, &prior).is_err());
    }

    #[test]
    fn offline_member_replays_ordered_commits_then_reads_current_epoch() {
        let alice = device("alice");
        let bob = device("bob");
        let group_id = b"yappa-text-v1|server|offline";
        alice.create_group(group_id).unwrap();
        let add = alice
            .prepare_add(group_id, &bob.generate_key_package().unwrap())
            .unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        bob.join_from_welcome(group_id, &add.welcome).unwrap();

        let first = alice.prepare_self_update(group_id).unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        let second = alice.prepare_self_update(group_id).unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        assert_eq!(bob.epoch(group_id).unwrap(), 1);
        assert_eq!(bob.process_commit(group_id, &first.commit).unwrap(), 2);
        assert_eq!(bob.process_commit(group_id, &second.commit).unwrap(), 3);

        let current = alice
            .encrypt_application(group_id, b"after offline replay")
            .unwrap();
        assert_eq!(
            bob.decrypt_application(group_id, &current)
                .unwrap()
                .plaintext,
            b"after offline replay"
        );
    }

    #[test]
    fn accepted_competing_commit_rolls_back_local_pending_commit() {
        let alice = device("alice");
        let bob = device("bob");
        let group_id = b"yappa-text-v1|server|concurrent";
        alice.create_group(group_id).unwrap();
        let add = alice
            .prepare_add(group_id, &bob.generate_key_package().unwrap())
            .unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        bob.join_from_welcome(group_id, &add.welcome).unwrap();

        let accepted = alice.prepare_self_update(group_id).unwrap();
        let stale = bob.prepare_self_update(group_id).unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        assert_eq!(bob.process_commit(group_id, &accepted.commit).unwrap(), 2);
        assert_eq!(bob.accept_pending_commit(group_id), Err(YappaMlsError::MissingState));
        assert!(alice.process_commit(group_id, &stale.commit).is_err());
        assert_eq!(alice.epoch(group_id).unwrap(), 2);
        assert_eq!(bob.epoch(group_id).unwrap(), 2);
    }

    #[test]
    fn replayed_application_ciphertext_is_rejected() {
        let alice = device("alice");
        let bob = device("bob");
        let group_id = b"yappa-text-v1|server|replay";
        alice.create_group(group_id).unwrap();
        let add = alice
            .prepare_add(group_id, &bob.generate_key_package().unwrap())
            .unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        bob.join_from_welcome(group_id, &add.welcome).unwrap();

        let wire = alice.encrypt_application(group_id, b"once").unwrap();
        assert_eq!(
            bob.decrypt_application(group_id, &wire).unwrap().plaintext,
            b"once"
        );
        assert!(bob.decrypt_application(group_id, &wire).is_err());
    }

    #[test]
    fn invalid_competing_commit_does_not_destroy_local_pending_commit() {
        let alice = device("alice");
        let group_id = b"yappa-text-v1|server|invalid-competing";
        alice.create_group(group_id).unwrap();
        let pending = alice.prepare_self_update(group_id).unwrap();
        assert_eq!(pending.accepted_epoch, 1);

        assert!(alice.process_commit(group_id, b"not an MLS commit").is_err());
        assert_eq!(alice.accept_pending_commit(group_id).unwrap(), 1);
    }

    #[test]
    fn tampering_and_context_substitution_fail_closed() {
        let alice = device("alice");
        let bob = device("bob");
        let group_id = b"yappa-text-v1|server|44";
        let wrong_group = b"yappa-text-v1|server|45";
        alice.create_group(group_id).unwrap();
        bob.create_group(wrong_group).unwrap();

        let prepared = alice
            .prepare_add(group_id, &bob.generate_key_package().unwrap())
            .unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        bob.join_from_welcome(group_id, &prepared.welcome).unwrap();
        let mut ciphertext = alice.encrypt_application(group_id, b"secret").unwrap();
        let last = ciphertext.len() - 1;
        ciphertext[last] ^= 1;

        assert!(matches!(
            bob.decrypt_application(group_id, &ciphertext),
            Err(YappaMlsError::CryptographicFailure)
                | Err(YappaMlsError::InvalidWireMessage)
        ));
        let valid = alice.encrypt_application(group_id, b"context").unwrap();
        assert!(bob.decrypt_application(wrong_group, &valid).is_err());
    }

    #[test]
    fn encrypted_state_restores_groups_and_rejects_tampering_or_wrong_context() {
        let alice = device("server|alice|device");
        let bob = device("server|bob|device");
        let group_id = b"yappa-text-v1|server|46";
        alice.create_group(group_id).unwrap();
        let prepared = alice
            .prepare_add(group_id, &bob.generate_key_package().unwrap())
            .unwrap();
        alice.accept_pending_commit(group_id).unwrap();
        bob.join_from_welcome(group_id, &prepared.welcome).unwrap();

        let wrapping_key = [7u8; 32];
        let context = b"server|bob-device";
        let encrypted = bob
            .export_encrypted_state(&wrapping_key, context)
            .unwrap();
        assert!(!encrypted
            .windows(b"server|bob|device".len())
            .any(|part| part == b"server|bob|device"));

        let restored =
            MlsDevice::import_encrypted_state(&wrapping_key, context, &encrypted)
                .unwrap();
        assert_eq!(restored.epoch(group_id).unwrap(), 1);
        assert_eq!(restored.signature_public_key(), bob.signature_public_key());
        let wire = alice
            .encrypt_application(group_id, b"after restart")
            .unwrap();
        assert_eq!(
            restored
                .decrypt_application(group_id, &wire)
                .unwrap()
                .plaintext,
            b"after restart"
        );

        let mut tampered = encrypted.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 1;
        assert!(MlsDevice::import_encrypted_state(
            &wrapping_key,
            context,
            &tampered
        )
        .is_err());
        assert!(MlsDevice::import_encrypted_state(
            &wrapping_key,
            b"other-server|bob-device",
            &encrypted
        )
        .is_err());
        assert!(MlsDevice::import_encrypted_state(
            &[8u8; 32],
            context,
            &encrypted
        )
        .is_err());
    }
}
