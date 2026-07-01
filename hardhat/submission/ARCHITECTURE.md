# Architecture Note — Commit-Reveal Bounty Judge

## Components

1. **`AiJudge` smart contract (on-chain)** — the source of truth for bounties,
   commitments, revealed answers, judging state, and reward custody/payout.
2. **Participant client (off-chain)** — generates the secret `salt`, computes the
   commitment, and later reveals. Holds the plaintext answer until reveal.
3. **Bounty owner / judging trigger (off-chain)** — after the reveal deadline,
   assembles `llmInput` from the *revealed* answers and calls `judgeAll`.
4. **Ritual AI inference precompile (on/side-chain)** — performs the batch LLM
   evaluation invoked from `judgeAll`; returns a completion the contract stores
   as `aiReview`.

## Where plaintext answers exist

| Time                         | Plaintext answer location                                              |
|------------------------------|------------------------------------------------------------------------|
| Before commit                | Only in the participant's client (local).                              |
| Commit phase                 | Only in the participant's client. On-chain there is **only the hash**. |
| Reveal phase                 | Sent in the `revealAnswer` calldata → stored on-chain in `Submission.answer`. |
| After reveal / judging       | Public on-chain (safe now — the submission window is closed).          |

The salt is **never** stored on-chain by the client until reveal; it is the
secret that keeps the commitment hiding. Losing it before revealing forfeits the
entry.

## On-chain vs off-chain

**On-chain (public, in contract storage):**
- Bounty metadata: `owner`, `title`, `rubric`, `reward`, `submissionDeadline`, `revealDeadline`.
- Per submission during commit phase: `submitter` address + `commitment` hash only.
- Per submission after reveal: the plaintext `answer` + `revealed` flag.
- Judging result: `aiReview` bytes, `judged`, `finalized`, `winnerIndex`.
- The reward (native funds held in escrow by the contract until `finalizeWinner`).

**Off-chain (private / not in contract):**
- The plaintext answer during the commit phase.
- The random `salt` (until reveal).
- The `llmInput` prompt/rubric packaging and the LLM model/provider config.

## Data flow

```
 Participant client                         AiJudge (on-chain)                 Ritual AI precompile
 ─────────────────                          ──────────────────                 ────────────────────
 answer + random salt
 commitment = keccak256(
   abi.encode(answer,salt,addr,id))
        │ submitCommitment(id, commitment)
        ├───────────────────────────────────►  store {submitter, commitment}
        │                                       (answer NOT present)
   ── submission deadline passes ──
        │ revealAnswer(id, answer, salt)
        ├───────────────────────────────────►  recompute hash, require ==
        │                                       store plaintext answer, revealed=true
   ── reveal deadline passes ──
 owner builds llmInput from
 the revealed answers
        │ judgeAll(id, llmInput)
        ├───────────────────────────────────►  gate: now≥revealDeadline,
        │                                       revealedCount>0
        │                                          │  batch inference call
        │                                          ├──────────────────────►  score all answers
        │                                          ◄──────────────────────   completion / ranking
        │                                       store aiReview, judged=true
        │ finalizeWinner(id, winnerIndex)
        ├───────────────────────────────────►  require winner.revealed
        │                                       transfer reward → winner
```

## How the LLM receives submissions for batch judging

`judgeAll` takes a single `llmInput` blob and makes **one** batched inference
call (not one call per answer). The owner/off-chain builder concatenates the
revealed answers together with the bounty `rubric` into that one prompt (e.g. a
numbered list of answers + "score each against this rubric and return a ranking
+ rationale"). Because only revealed answers exist in storage by the time
`judgeAll` is callable, the builder cannot accidentally include a hidden answer,
and the contract enforces `revealedCount > 0` and `now ≥ revealDeadline`. The
returned completion is stored on-chain as `aiReview`; a human owner then reads
the ranking and calls `finalizeWinner`.

## Threat model — what commit-reveal defends against

| Threat | Defense |
|--------|---------|
| Copying a rival's answer during submission | Only hashes are on-chain in the commit phase; plaintext is unreadable. |
| Swapping in a better answer after seeing others | The hash binds the answer; a different answer fails the reveal check. |
| Stealing/claiming another's answer | `msg.sender` is bound into the commitment. |
| Replaying a commitment across bounties | `bountyId` is bound into the commitment. |
| Brute-forcing the answer from the hash | Random 32-byte `salt` makes pre-image search infeasible. |
| Judging leaking hidden answers | `judgeAll` gated to `now ≥ revealDeadline`; only revealed answers eligible. |
| Paying an un-revealed entry | `finalizeWinner` requires `winner.revealed`. |

### Residual risks / assumptions
- **Last-actor reveal advantage:** in the reveal window everyone's answer becomes
  visible; a griefer could choose *not* to reveal, but that only forfeits their
  own entry — it cannot copy or alter others'. (An optional commit-bond could
  discourage no-shows.)
- **Owner trust:** the bounty owner triggers judging and picks the winner index.
  The AI provides a ranking + rationale; final authority is human (see
  `REFLECTION.md`).
- **Mempool at reveal time:** reveal transactions expose plaintext, but by then
  the submission window is already closed, so front-running yields no copy-and-resubmit advantage.

## Relationship to the Advanced (Ritual-native) track

Commit-reveal keeps answers hidden **until the reveal deadline**. The advanced
track would instead keep answers *encrypted* and only ever decrypt them **inside
Ritual's TEE at the judging step**, so plaintext never needs to appear in public
on-chain storage at all: participants would store encrypted answers (on-chain
blob or off-chain pointer) plus a secret sealed to the enclave via Ritual's
DKMS/secrets, and `judgeAll` would decrypt-and-batch-judge inside the TEE,
emitting only the ranking. This submission implements the **Required
(commit-reveal)** track; the above is noted for completeness.
