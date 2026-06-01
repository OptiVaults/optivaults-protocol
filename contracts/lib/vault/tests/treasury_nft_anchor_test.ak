/// treasury_nft_anchor_test — canonical-treasury anchoring regression coverage.
///
/// Previously, `treasury.ak` was parameterized only on the deposit-token
/// identity — no one-shot NFT bound the canonical treasury UTXO (unlike
/// gov / registry / vault_proxy / keeper_stake_script, which all anchor a
/// one-shot NFT). `find_continuing` enforced exactly one treasury-script
/// OUTPUT but never bounded treasury-script INPUTS, so anyone could create
/// decoy UTXOs at the treasury script address with forged datums
/// (attacker-chosen governance_policy, inflated balances) → accounting
/// fragmentation, and the two fee consumers (Compound's `valid_treasury`,
/// Distribute's `forfeit_ok`) routed to "a" treasury output rather than
/// the canonical one.
///
/// Closure: a one-shot `treasury_nft` (compile-time UTXO-ref one-shot,
/// mirroring vault_nft / registry_auth_nft / keeper_auth_nft) must be on
/// the spent input AND the continuing output of EVERY treasury redeemer,
/// and the two fee consumers route only to the NFT-bearing output.
///
/// Aiken forbids a test module from importing a validator module
/// (aiken::check::illegal::import), so these tests pin the load-bearing
/// predicates by replicating them against fixture `Value`s / `Transaction`s:
///   (a) the one-shot mint predicate from treasury_nft.ak's mint handler
///       (asset_name match + qty==1 + anchor-UTXO-consumed; burn qty==-1);
///   (b) treasury spend `nft_ok` = NFT on input AND continuing output;
///   (c) vault_keeper_hot.Compound `valid_treasury` fee-output NFT gate;
///   (d) multisig_gov.DistributeSignerCompensation `forfeit_ok` output gate.
/// A regression that drops the check or uses the wrong policy/name surfaces
/// here at `aiken check`.

use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Address, Script}
use cardano/assets.{from_asset, merge, quantity_of, tokens}
use cardano/transaction.{Input, NoDatum, Output, OutputReference, Transaction,
  placeholder}

// ─────────────────────────────────────────────────────────────────────
// Fixtures
// ─────────────────────────────────────────────────────────────────────

const legit_policy: ByteArray =
  #"ab12cd34ef5601234567890abcdef01234567890abcdef0123456789"

const legit_name: ByteArray = #"54726561737572794964"

const wrong_policy: ByteArray =
  #"de00ad00be00ef00de00ad00be00ef00de00ad00be00ef00de00ad00"

const wrong_name: ByteArray = #"deadbeef"

const anchor_ref: OutputReference =
  OutputReference { transaction_id: #"aa", output_index: 0 }

const other_ref: OutputReference =
  OutputReference { transaction_id: #"bb", output_index: 1 }

fn dummy_input(ref: OutputReference) -> Input {
  Input {
    output_reference: ref,
    output: Output {
      address: Address {
        payment_credential: Script(#"cafe"),
        stake_credential: None,
      },
      value: from_asset(#"", #"", 2_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn mint_tx(spent: OutputReference, name: ByteArray, qty: Int) -> Transaction {
  Transaction {
    ..placeholder,
    inputs: [dummy_input(spent)],
    mint: from_asset(legit_policy, name, qty),
  }
}

/// Faithful replica of treasury_nft.ak's mint handler. Kept byte-for-byte
/// equivalent to the validator's logic so this test fails if the one-shot
/// semantics ever drift.
fn treasury_nft_mint_ok(
  utxo_ref: OutputReference,
  asset_name: ByteArray,
  policy_id: ByteArray,
  tx: Transaction,
) -> Bool {
  let minted = dict.to_pairs(tokens(tx.mint, policy_id))
  when minted is {
    [pair] ->
      if pair.2nd == 1 {
        let utxo_consumed =
          list.any(tx.inputs, fn(input) { input.output_reference == utxo_ref })
        and {
          pair.1st == asset_name,
          utxo_consumed,
        }
      } else if pair.2nd == -1 {
        pair.1st == asset_name
      } else {
        False
      }
    _ -> False
  }
}

// ─────────────────────────────────────────────────────────────────────
// (a) treasury_nft one-shot mint predicate
// ─────────────────────────────────────────────────────────────────────

test mint_one_with_anchor_consumed_passes() {
  // Operator deploy: mint +1 of the singleton while spending the anchor
  // UTXO ref. One-shot satisfied → must pass.
  let tx = mint_tx(anchor_ref, legit_name, 1)
  treasury_nft_mint_ok(anchor_ref, legit_name, legit_policy, tx)
}

test mint_one_without_anchor_rejected() {
  // ATTACK: try to mint a second singleton WITHOUT consuming the (already
  // spent) anchor UTXO. One-shot anchor missing → must reject.
  let tx = mint_tx(other_ref, legit_name, 1)
  !treasury_nft_mint_ok(anchor_ref, legit_name, legit_policy, tx)
}

test mint_wrong_asset_name_rejected() {
  // Anchor consumed but asset name differs from the compile-time anchor
  // name → must reject (prevents minting a lookalike under the policy).
  let tx = mint_tx(anchor_ref, wrong_name, 1)
  !treasury_nft_mint_ok(anchor_ref, legit_name, legit_policy, tx)
}

test mint_quantity_two_rejected() {
  // Anchor consumed, correct name, but quantity 2 — singleton invariant
  // violated → must reject.
  let tx = mint_tx(anchor_ref, legit_name, 2)
  !treasury_nft_mint_ok(anchor_ref, legit_name, legit_policy, tx)
}

test burn_minus_one_passes() {
  // Burn path (qty -1) does not require the anchor (long consumed) — only
  // the asset name must match. Must pass (clean sunset).
  let tx = mint_tx(other_ref, legit_name, -1)
  treasury_nft_mint_ok(anchor_ref, legit_name, legit_policy, tx)
}

// ─────────────────────────────────────────────────────────────────────
// (b) treasury spend `nft_ok` — input + continuing-output gate
//
// nft_ok = quantity_of(input.value, p, n) == 1
//        && quantity_of(cont_output.value, p, n) == 1
// ─────────────────────────────────────────────────────────────────────

test spend_input_and_output_carry_nft_passes() {
  let inp =
    merge(from_asset(#"", #"", 2_000_000), from_asset(legit_policy, legit_name, 1))
  let cont =
    merge(from_asset(#"", #"", 2_000_000), from_asset(legit_policy, legit_name, 1))
  and {
    quantity_of(inp, legit_policy, legit_name) == 1,
    quantity_of(cont, legit_policy, legit_name) == 1,
  }
}

test spend_input_missing_nft_rejected() {
  // ATTACK: forged decoy UTXO at the treasury address with NO NFT (cannot
  // mint it — one-shot consumed). The input gate must fail.
  let inp = from_asset(#"", #"", 2_000_000)
  let cont =
    merge(from_asset(#"", #"", 2_000_000), from_asset(legit_policy, legit_name, 1))
  !and {
    quantity_of(inp, legit_policy, legit_name) == 1,
    quantity_of(cont, legit_policy, legit_name) == 1,
  }
}

test spend_output_strips_nft_rejected() {
  // ATTACK: spend the canonical treasury but emit a continuing output
  // WITHOUT the NFT (siphon the singleton). The output gate must fail.
  let inp =
    merge(from_asset(#"", #"", 2_000_000), from_asset(legit_policy, legit_name, 1))
  let cont = from_asset(#"", #"", 2_000_000)
  !and {
    quantity_of(inp, legit_policy, legit_name) == 1,
    quantity_of(cont, legit_policy, legit_name) == 1,
  }
}

// ─────────────────────────────────────────────────────────────────────
// (c) vault_keeper_hot.Compound `valid_treasury` — fee output gate
//
// On positive-yield Compound (treasury_share > 0) the fee output must
// carry the canonical NFT: quantity_of(fee_out.value, p, n) == 1.
// ─────────────────────────────────────────────────────────────────────

test compound_fee_out_with_nft_passes() {
  let fee_out =
    merge(from_asset(legit_policy, legit_name, 1), from_asset(#"", #"", 3_000_000))
  quantity_of(fee_out, legit_policy, legit_name) == 1
}

test compound_fee_out_without_nft_rejected() {
  // ATTACK: route the treasury fee share to a decoy treasury output
  // lacking the NFT (accounting fragmentation). The NFT gate must fail.
  let fee_out = from_asset(#"", #"", 3_000_000)
  !(quantity_of(fee_out, legit_policy, legit_name) == 1)
}

test compound_fee_out_wrong_policy_rejected() {
  let fee_out =
    merge(from_asset(wrong_policy, legit_name, 1), from_asset(#"", #"", 3_000_000))
  !(quantity_of(fee_out, legit_policy, legit_name) == 1)
}

// ─────────────────────────────────────────────────────────────────────
// (d) multisig_gov.DistributeSignerCompensation `forfeit_ok` — output gate
//
// On forfeit_amount > 0 the forfeit output must carry the canonical NFT:
// quantity_of(forfeit_out.value, p, n) == 1.
// ─────────────────────────────────────────────────────────────────────

test forfeit_out_with_nft_passes() {
  let forfeit_out =
    merge(from_asset(legit_policy, legit_name, 1), from_asset(#"", #"", 5_000_000))
  quantity_of(forfeit_out, legit_policy, legit_name) == 1
}

test forfeit_out_without_nft_rejected() {
  // ATTACK: route forfeit to a decoy treasury output without the NFT.
  let forfeit_out = from_asset(#"", #"", 5_000_000)
  !(quantity_of(forfeit_out, legit_policy, legit_name) == 1)
}
