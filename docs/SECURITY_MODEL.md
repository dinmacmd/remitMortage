# RemitMortgage Security Model

This document specifies the trust model, access control, threat vectors, and
mitigations for the RemitMortgage protocol. It is intended to align the
codebase with NexusGuard review templates and to give third-party auditors a
single reference for the security posture of the four Soroban contracts:

| Contract | Responsibility |
| --- | --- |
| `escrow` | Holds borrower down-payment savings; tiered early-withdrawal penalties; release/refund. |
| `lending-pool` | Holds investor capital across Senior/Junior tranches; originates and services loans; distributes yield. |
| `milestone` | Releases construction funds to contractors on multisig-approved milestones. |
| `verification-registry` | Records borrower/contractor verification attestations. |

> Scope note: this is a living document. Where the contract source and this
> document disagree, the source is authoritative — open an issue so the model
> can be corrected.

---

## 1. Roles and Permissions

The protocol recognises five principal roles. Every privileged entry point
calls `require_auth()` on the relevant address; the table below is the
canonical list of who may do what.

| Role | Holder | Can do | Cannot do |
| --- | --- | --- | --- |
| **Admin** | Single account set at `initialize` (intended to be a multisig account; see §3). | Release matured escrow, remove defaulters, set timelock/delay params, pause/unpause, propose admin transfer, queue contract upgrades. | Move investor capital arbitrarily, vote on milestones, mint yield, bypass timelocks. |
| **Governance signers** | The `approvers` set configured in the `milestone` contract. | Vote to approve milestones, dispute milestones. | Disburse funds directly, alter loan terms, withdraw investor capital. |
| **Contractors** | Whitelisted construction counterparties. | Propose milestone completion with IPFS evidence; receive milestone disbursements. | Self-approve their own milestones, release funds, vote. |
| **Borrowers** | Savers/loan applicants. | Deposit to escrow, withdraw early (with penalty), request loans, repay loans. | Touch other borrowers' records, release their own escrow early without penalty, mint yield. |
| **Investors** | Senior/Junior tranche depositors. | Deposit to the pool, claim yield, withdraw available liquidity. | Force loan approval, redirect another investor's yield, withdraw past the liquidity available after active commitments. |

### Permission boundaries enforced in code

- **Escrow** — `release`, `remove_defaulter`, pause/unpause, and admin transfer
  require `config.admin`. `withdraw` and `deposit` require the borrower
  themselves. Borrower records are keyed by `(Address, Symbol goal_id)` so one
  borrower can never read or mutate another's balance.
- **Lending pool** — `deposit`, `withdraw`, and `claim_yield` require the
  investor. Loan lifecycle transitions (`approve_loan`, `disburse`,
  `mark_default`, `recover_default`) require the configured admin/operator.
  Yield is computed pro-rata from aggregate state, never set by a caller.
- **Milestone** — `propose_milestone` requires the contractor; `approve_milestone`
  and `dispute_milestone` require an address present in the `approvers` set;
  `release_milestone` requires the admin **and** a satisfied timelock.
- **Verification registry** — attestation writes require the registry admin.

---

## 2. Trust Assumptions

1. **Admin key custody.** The admin is the most powerful role. The protocol
   assumes admin authority is held by a Stellar multisig account with a
   threshold > 1, not a single hot key. Compromise of a single-signer admin is
   treated as a critical-severity event (see §4).
2. **Governance honesty (m-of-n).** Milestone approval assumes that fewer than
   the threshold number of governance signers are malicious or compromised at
   once. A colluding majority of signers can approve a fraudulent milestone.
3. **Token correctness.** All contracts assume the configured USDC token
   contract is a well-behaved SEP-41 token (no reentrancy callbacks into our
   contracts, honest balances, no fee-on-transfer surprises).
4. **Oracle/off-chain inputs.** IPFS evidence hashes and verification
   attestations are trusted to be produced by authorised off-chain services.
   On-chain logic verifies authorisation and format, not the truthfulness of
   the underlying document.
5. **Ledger time.** Timelocks are expressed in ledger sequence numbers and
   assume roughly 5-second ledger close times; large deviations shift wall-clock
   delay but never shorten the relative ordering guarantees.

---

## 3. Threat Vector Analysis

### 3.1 Escrow contract

| Threat | Vector | Mitigation |
| --- | --- | --- |
| Early-exit fee evasion | Borrower withdraws just before a tier boundary to dodge the higher penalty. | Penalty tier is derived deterministically from `start_ledger`; tiers only increase over time, so waiting never reduces the penalty owed for past months. |
| Double withdrawal / replay | Borrower calls `withdraw` or `release` twice. | `withdrawn` / `released` flags are checked and set atomically; `deposited` is zeroed on exit. |
| Cross-borrower tampering | Caller targets another borrower's `goal_id`. | Records keyed by `(Address, Symbol)`; `borrower.require_auth()` ties the caller to the record. |
| Penalty front-running | Observer races a borrower's `withdraw`. | Penalty is a pure function of the borrower's own record; a third party cannot extract value from another's withdrawal. |
| Stuck funds on default | Borrower stops contributing. | `remove_defaulter` lets the admin reclaim after `grace_period_ledgers`, applying `default_penalty_bps`. |

### 3.2 Lending pool contract

| Threat | Vector | Mitigation |
| --- | --- | --- |
| Yield theft | Investor claims more than their pro-rata share. | `claim_yield` computes `(deposited * total_interest) / total_deposited` and subtracts `claimed_yield`; over-claiming is arithmetically impossible. |
| Liquidity drain / bank run | Investor withdraws capital pledged to active loans. | `get_available_withdrawal` caps withdrawals at `liquidity - active_loan_commitments`. |
| Reentrancy on repay/disburse | Malicious token re-enters during transfer. | State (loan status, liquidity, commitments) is updated **before/around** external `token.transfer`, following checks-effects-interactions; Soroban's auth framework also blocks unauthorised nested calls. |
| Self-dealing loan origination | Operator originates a loan to themselves on favourable terms. | Loan approval is admin-gated and surfaced off-chain via `detectSelfDealing`; disbursement is milestone-gated rather than lump-sum. |
| Default loss socialisation abuse | Inflating defaults to manipulate loss ratios. | `mark_default` requires overdue conditions (`is_loan_overdue`); losses are tracked separately in `total_defaulted_loss`. |

### 3.3 Milestone contract

| Threat | Vector | Mitigation |
| --- | --- | --- |
| Self-dealing disbursement | Contractor approves and releases their own milestone. | Proposing requires the contractor; approving requires a *different* governance signer; releasing requires the admin. Roles are disjoint. |
| Vote stuffing | One approver votes many times. | `DataKey::Voted(proposal_id, approver)` enforces one vote per approver per proposal. |
| Premature release / rug | Admin releases immediately after approval. | `min_delay_ledgers` timelock between `approved_ledger` and release gives signers a dispute window. |
| Over-release | Releasing a milestone twice. | Status machine `Proposed → Approved → Disbursed`; release requires `Approved` and transitions to `Disbursed`. |
| Fake evidence | Contractor submits an empty/garbage CID. | Zeroed `evidence_hash` is rejected; `validate_cid` enforces CIDv0/CIDv1 shape. |
| Disputed fund recovery | Funds already paid on a bad milestone. | `dispute_milestone` (governance-only) refunds the pool via cross-contract call and marks `Refunded`. |

### 3.4 Verification registry

| Threat | Vector | Mitigation |
| --- | --- | --- |
| Forged attestation | Non-admin writes a verification record. | Attestation writes are admin-gated. |
| Replay of off-chain proof | Reusing a captured signature. | Off-chain challenge/nonce flow (single-use, TTL-bounded) precedes any on-chain attestation. |

### 3.5 Cross-cutting: key compromise

| Threat | Mitigation |
| --- | --- |
| Admin key theft | Admin should be a multisig; pausability limits blast radius; two-step admin transfer prevents a single fat-finger handover. |
| Governance signer theft | m-of-n threshold tolerates up to `n - threshold` compromised signers; dispute window allows honest signers to react. |
| Upgrade key abuse | Contract upgrades are queued behind a configurable timelock (`UpgradeDelay`), giving users an exit window. |

---

## 4. Protective Mechanisms

### 4.1 Pausability (emergency stop)
The escrow contract exposes an admin-only pause flag (`DataKey::Paused`).
`check_not_paused` gates deposits and withdrawals so the admin can freeze
value-moving operations during an incident without affecting read-only views or
the ability to investigate. Pause is reversible by the admin.

### 4.2 Two-step admin transfer
Admin handover uses a propose/accept pattern (`PendingAdmin`): the current
admin nominates a successor, and the nominee must explicitly accept. This
prevents transferring control to a mistyped or uncontrolled address and removes
the single point of failure of an instantaneous transfer.

### 4.3 Timelocks
- **Milestone release** waits `min_delay_ledgers` after approval — a live
  dispute window for governance.
- **Contract upgrades** wait `UpgradeDelay` ledgers between proposal and
  execution — a user exit window.

### 4.4 Multisig governance
Milestone approval requires `threshold` distinct approvals from the `approvers`
set, with `0 < threshold <= approvers.len()` enforced at `initialize`. See the
multisig threshold validator work for native signature-weight verification.

### 4.5 Checks-Effects-Interactions
All contracts update internal accounting before performing external token
transfers, and rely on Soroban's authorisation framework (which requires
explicit `require_auth` and does not grant ambient authority to re-entrant
calls) to neutralise classic reentrancy.

---

## 5. Security Audit Best Practices for Soroban

Auditors and contributors should verify the following Soroban-specific
practices, which the protocol aims to follow:

- **Explicit authorization.** Every state-changing entry point calls
  `require_auth()` on the principal whose authority it relies on. There is no
  ambient authority in Soroban — missing `require_auth` is the most common
  high-severity finding.
- **Integer overflow protection.** The workspace builds with
  `overflow-checks = true`; arithmetic on `i128` balances traps on overflow
  rather than wrapping.
- **Storage TTL management.** Contracts bump instance/persistent TTLs
  (`extend_ttl`) so live records are not archived out from under users.
- **Deterministic, panic-on-error semantics.** `panic = "abort"` and typed
  `contracterror` enums make failures revert the whole transaction; no partial
  state is committed.
- **No floating point / no host randomness for value logic.** All financial
  math is integer basis-point arithmetic.
- **Cross-contract trust.** Calls to the token, lending pool, and milestone
  contracts assume only the documented interface; failures propagate as traps
  (or are handled via `try_invoke_contract` where graceful degradation is
  intended).
- **Test coverage of negative paths.** Unit and fuzz tests assert that
  unauthorised callers, double-spends, and threshold violations *fail*.

### Recommended external references
- Stellar Soroban security guidance: <https://developers.stellar.org/docs/build/security-docs>
- Soroban authorization model: <https://developers.stellar.org/docs/learn/fundamentals/contract-development/authorization>
- OpenZeppelin Stellar/Soroban contracts & audits: <https://github.com/OpenZeppelin/stellar-contracts>
- General smart-contract checklist (concepts transferable to Soroban): <https://github.com/crytic/building-secure-contracts>

---

## 6. Reporting

Suspected vulnerabilities should be reported privately to the maintainers
before public disclosure. Include the affected contract, a reproduction path,
and the expected vs. actual behaviour.

Recurring penetration test engagements are scheduled quarterly and findings
are tracked through to remediation via GitHub issues — see
[`docs/PENTEST_PROGRAM.md`](PENTEST_PROGRAM.md) for the scheduling workflow,
findings tracker, and open-findings dashboard.
