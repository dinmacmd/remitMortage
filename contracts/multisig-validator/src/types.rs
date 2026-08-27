use soroban_sdk::{contracttype, Address, BytesN, Vec};

/// A single weighted signer of a multisig account, mirroring a Stellar
/// account's `signer { key, weight }` entry. `key` is the Ed25519 public key.
#[contracttype]
#[derive(Clone, Debug, PartialEq)]
pub struct Signer {
    /// Ed25519 public key of the signer.
    pub key: BytesN<32>,
    /// Voting weight contributed by this signer.
    pub weight: u32,
}

/// The stored multisig configuration for an account: its weighted signer set
/// and the cumulative weight required to authorize an operation.
#[contracttype]
#[derive(Clone, Debug, PartialEq)]
pub struct MultisigConfig {
    /// The configured weighted signers.
    pub signers: Vec<Signer>,
    /// Required cumulative weight (the "high"/medium threshold).
    pub threshold: u32,
}

/// Timelock configuration for an account.
#[contracttype]
#[derive(Clone, Debug, PartialEq)]
pub struct TimelockConfig {
    /// Delay in seconds that must elapse after threshold is met.
    pub delay_seconds: u64,
}

/// State of a timelocked action proposal.
#[contracttype]
#[derive(Clone, Debug, PartialEq)]
pub enum ProposalState {
    /// Submitted but has not yet reached the approval threshold.
    Pending,
    /// Threshold met; waiting for the timelock delay to elapse.
    Locked,
    /// Successfully executed.
    Executed,
}

/// A timelocked action proposal.
#[contracttype]
#[derive(Clone, Debug, PartialEq)]
pub struct Proposal {
    pub state: ProposalState,
    /// Ledger timestamp when threshold was met (0 if still Pending).
    pub ready_at: u64,
    /// Ledger timestamp when the proposal was first submitted.
    pub created_at: u64,
    /// Ledger sequence number after which this proposal is considered expired.
    /// Once `env.ledger().sequence() > expiration_ledger` the proposal cannot
    /// be voted on or executed and is eligible for pruning.
    ///
    /// Set at submission time.  A value of 0 means no expiry (legacy records
    /// created before this field existed are treated as non-expiring).
    pub expiration_ledger: u32,
}

/// Admin-managed multisig configuration: the required signature threshold and
/// the set of addresses permitted to sign. Unlike the per-account weighted
/// [`MultisigConfig`], this models a simple `k-of-n` signer group (e.g. 2-of-3,
/// 3-of-5) that the contract admin can reconfigure over time.
#[contracttype]
#[derive(Clone, Debug, PartialEq)]
pub struct AdminMultisigConfig {
    /// Addresses permitted to sign (the "n").
    pub signers: Vec<Address>,
    /// Number of distinct signatures required to authorize (the "k").
    pub threshold: u32,
}

/// Configuration for the missed-vote slashing penalty system.
#[contracttype]
#[derive(Clone, Debug, PartialEq)]
pub struct SlashingConfig {
    /// Number of consecutive missed votes that triggers a penalty.
    pub missed_vote_threshold: u32,
    /// Percentage of voting weight to reduce when penalized (0-100).
    /// E.g. 50 means the signer's effective weight is halved.
    pub penalty_weight_reduction_pct: u32,
    /// Number of consecutive active votes required to reset the penalty.
    pub recovery_active_votes: u32,
}

impl Default for SlashingConfig {
    fn default() -> Self {
        Self {
            missed_vote_threshold: 3,
            penalty_weight_reduction_pct: 50,
            recovery_active_votes: 3,
        }
    }
}

/// Tracks missed-vote and recovery state for a single signer within an account.
#[contracttype]
#[derive(Clone, Debug, PartialEq)]
pub struct SignerVoteRecord {
    /// Consecutive proposals this signer missed (resets to 0 on vote).
    pub consecutive_missed: u32,
    /// Consecutive proposals this signer voted on (for penalty recovery).
    pub consecutive_active: u32,
    /// Whether the signer is currently penalized (weight reduced).
    pub penalized: bool,
}

/// Storage keys.
#[contracttype]
#[derive(Clone)]
pub enum DataKey {
    /// Per-account multisig configuration, keyed by the account address.
    Config(Address),
    /// Per-account timelock configuration.
    TimelockConfig(Address),
    /// A timelocked action proposal, keyed by proposal ID (32-byte hash).
    ActionProposal(BytesN<32>),
    /// The admin authorized to reconfigure the admin-managed signer set.
    Admin,
    /// The admin-managed `k-of-n` signer configuration.
    AdminConfig,
    /// Slashing configuration for missed votes.
    SlashingConfig,
    /// Per-signer vote record: (account, signer_address) -> SignerVoteRecord.
    SignerVoteRecord(Address, Address),
}
