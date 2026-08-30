use soroban_sdk::contracterror;

#[contracterror]
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[repr(u32)]
pub enum EscrowError {
    /// Contract has already been initialized.
    AlreadyInitialized = 1,
    /// Contract has not been initialized yet.
    NotInitialized = 2,
    /// Deposit amount must be greater than zero.
    InvalidAmount = 3,
    /// Borrower has already completed their savings and funds were released.
    AlreadyReleased = 4,
    /// Borrower has already withdrawn.
    AlreadyWithdrawn = 5,
    /// Savings target has not been reached yet.
    TargetNotReached = 6,
    /// Only the admin can call this function.
    Unauthorized = 7,
    /// The savings period has expired.
    PeriodExpired = 8,
    /// Borrower record not found.
    BorrowerNotFound = 9,
    /// Collateral has already been seized.
    AlreadySeized = 10,
    /// No pending upgrade exists to execute.
    UpgradeNotPending = 11,
    /// Upgrade was proposed but the timelock delay has not elapsed yet.
    UpgradeTimelockActive = 12,
    /// The borrower's grace period has not yet expired; removal is not allowed.
    GracePeriodActive = 13,
    /// The borrower is not in default and cannot be forcibly removed.
    BorrowerNotInDefault = 14,
    /// Minimum savings lockup period has not elapsed yet.
    LockupNotMet = 18,
    /// Operation rejected because the contract is paused.
    ContractPaused = 15,
    /// Proposed new admin is not the caller or no transfer is pending.
    NotPendingAdmin = 16,
    /// Cross-contract bridge call to the lending pool failed.
    BridgeFailed = 17,
    /// Penalty tier values must be within basis-points bounds.
    InvalidPenaltyBps = 19,
    /// Reentrant call detected — mutating function already in progress.
    ReentrancyGuard = 20,
    /// TTL bump amounts and lifetime thresholds must be greater than zero.
    InvalidTtlConfig = 21,
    /// Penalty proposal is not pending.
    PenaltyProposalNotPending = 22,
    /// Escrow goal does not exist or has no deposits.
    EscrowGoalNotFound = 23,
    /// No beneficiary is configured for the owner and goal.
    BeneficiaryNotConfigured = 24,
    /// Caller is not the configured beneficiary.
    UnauthorizedBeneficiary = 25,
    /// The configured inactivity period has not elapsed.
    BeneficiaryInactivityNotElapsed = 26,
    /// Provided attestors do not satisfy the configured quorum.
    InsufficientAttestationQuorum = 27,
    /// An attestation is malformed, duplicated, or from an unknown signer.
    InvalidAttestation = 28,
    /// The beneficiary recovery has already completed.
    BeneficiaryAlreadyClaimed = 29,
    /// The escrow has no funds that can be recovered.
    NoClaimableFunds = 30,
    /// The configured inactivity period is invalid.
    InvalidInactivityPeriod = 31,
    /// The configured attestor set or quorum is invalid.
    InvalidAttestorConfig = 32,
}
