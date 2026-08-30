use super::*;
use soroban_sdk::{
    testutils::{Address as _, Ledger},
    token::{Client as TokenClient, StellarAssetClient},
    Address, Env, Symbol, Vec,
};

fn setup(
    env: &Env,
) -> (
    Address,
    Address,
    Address,
    Address,
    EscrowContractClient<'_>,
    Symbol,
) {
    env.mock_all_auths();
    let admin = Address::generate(env);
    let owner = Address::generate(env);
    let beneficiary = Address::generate(env);
    let attestor = Address::generate(env);
    let token = env
        .register_stellar_asset_contract_v2(Address::generate(env))
        .address();
    StellarAssetClient::new(env, &token).mint(&owner, &1_000);

    let contract = env.register(EscrowContract, ());
    let client = EscrowContractClient::new(env, &contract);
    client.initialize(&EscrowConfig {
        admin,
        token: token.clone(),
        lending_pool: Address::generate(env),
        savings_target: 1_000,
        max_duration_ledgers: 100,
        early_withdrawal_penalty_bps: 0,
        min_duration_ledgers: 0,
        penalty_bps_tier1: 0,
        penalty_bps_tier2: 0,
        penalty_bps_tier3: 0,
        penalty_bps_tier4: 0,
        grace_period_ledgers: 1,
        default_penalty_bps: 0,
        instance_bump_amount: 1_000,
        instance_lifetime_threshold: 100,
        persistent_bump_amount: 1_000,
        persistent_lifetime_threshold: 100,
        yield_vault: None,
    });
    client.set_beneficiary_inactivity(&10);
    client.configure_beneficiary_attestors(&Vec::from_array(env, [attestor.clone()]), &1);
    let goal = Symbol::new(env, "home");
    client.deposit(&owner, &goal, &500);
    (owner, beneficiary, attestor, token, client, goal)
}

#[test]
fn owner_can_set_replace_and_remove_beneficiary() {
    let env = Env::default();
    let (owner, beneficiary, _attestor, _token, client, goal) = setup(&env);
    let replacement = Address::generate(&env);

    client.set_beneficiary(&owner, &goal, &Some(beneficiary));
    client.set_beneficiary(&owner, &goal, &Some(replacement.clone()));
    assert_eq!(client.get_beneficiary(&owner, &goal), Some(replacement));
    client.set_beneficiary(&owner, &goal, &None);
    assert_eq!(client.get_beneficiary(&owner, &goal), None);
}

#[test]
fn inactivity_and_attestation_are_both_required() {
    let env = Env::default();
    let (owner, beneficiary, attestor, _token, client, goal) = setup(&env);
    client.set_beneficiary(&owner, &goal, &Some(beneficiary.clone()));
    let attestations = Vec::from_array(&env, [attestor.clone()]);

    assert_eq!(
        client
            .try_claim_as_beneficiary(&owner, &goal, &beneficiary, &attestations)
            .unwrap_err(),
        Ok(EscrowError::BeneficiaryInactivityNotElapsed)
    );

    env.ledger()
        .set_sequence_number(env.ledger().sequence() + 10);
    assert_eq!(
        client
            .try_claim_as_beneficiary(&owner, &goal, &beneficiary, &Vec::new(&env))
            .unwrap_err(),
        Ok(EscrowError::InsufficientAttestationQuorum)
    );
}

#[test]
fn wrong_beneficiary_and_unknown_attestor_are_rejected() {
    let env = Env::default();
    let (owner, beneficiary, _attestor, _token, client, goal) = setup(&env);
    let stranger = Address::generate(&env);
    client.set_beneficiary(&owner, &goal, &Some(beneficiary.clone()));
    env.ledger()
        .set_sequence_number(env.ledger().sequence() + 10);

    assert_eq!(
        client
            .try_claim_as_beneficiary(&owner, &goal, &stranger, &Vec::new(&env))
            .unwrap_err(),
        Ok(EscrowError::UnauthorizedBeneficiary)
    );
    assert_eq!(
        client
            .try_claim_as_beneficiary(
                &owner,
                &goal,
                &beneficiary,
                &Vec::from_array(&env, [stranger]),
            )
            .unwrap_err(),
        Ok(EscrowError::InvalidAttestation)
    );
}

#[test]
fn owner_activity_restarts_the_inactivity_window() {
    let env = Env::default();
    let (owner, beneficiary, attestor, _token, client, goal) = setup(&env);
    client.set_beneficiary(&owner, &goal, &Some(beneficiary.clone()));
    env.ledger()
        .set_sequence_number(env.ledger().sequence() + 9);
    client.top_up(&owner, &goal, &100);
    env.ledger()
        .set_sequence_number(env.ledger().sequence() + 9);

    let attestations = Vec::from_array(&env, [attestor]);
    assert_eq!(
        client
            .try_claim_as_beneficiary(&owner, &goal, &beneficiary, &attestations)
            .unwrap_err(),
        Ok(EscrowError::BeneficiaryInactivityNotElapsed)
    );
}

#[test]
fn valid_claim_transfers_funds_and_cannot_repeat() {
    let env = Env::default();
    let (owner, beneficiary, attestor, token, client, goal) = setup(&env);
    client.set_beneficiary(&owner, &goal, &Some(beneficiary.clone()));
    env.ledger()
        .set_sequence_number(env.ledger().sequence() + 10);
    let attestations = Vec::from_array(&env, [attestor]);

    assert_eq!(
        client.claim_as_beneficiary(&owner, &goal, &beneficiary, &attestations),
        500
    );
    assert_eq!(TokenClient::new(&env, &token).balance(&beneficiary), 500);
    assert_eq!(
        client
            .try_claim_as_beneficiary(&owner, &goal, &beneficiary, &attestations)
            .unwrap_err(),
        Ok(EscrowError::BeneficiaryAlreadyClaimed)
    );
}
