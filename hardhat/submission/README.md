# Commit-Reveal Bounty Judge — Lifecycle README

## The problem we are fixing

In the previous version of the Bounty Judge, participants called
`submitAnswer(bountyId, answer)` and the **plaintext answer was written to
on-chain storage immediately**. Because anything on-chain is public, later
participants could read earlier submissions, copy the best ideas, tweak them,
and submit an "improved" version before the deadline. The submission phase
leaked information and rewarded copying instead of original work.

## The fix: commit-reveal

We split a submission into two phases so that **nothing readable about an answer
exists on-chain until after the submission window has closed**.

1. **Commit phase** — a participant submits only a *commitment hash*:

   ```
   commitment = keccak256(abi.encode(answer, salt, msg.sender, bountyId))
   ```

   The hash reveals nothing about the answer (the random `salt` makes it
   infeasible to brute-force or dictionary-attack), so rivals learn nothing they
   can copy.

2. **Reveal phase** — after the submission deadline, the participant sends the
   plaintext `answer` and `salt`. The contract recomputes the hash and accepts
   the reveal **only if it matches the stored commitment**. A participant cannot
   change their answer after committing (any change breaks the hash), and cannot
   claim someone else's answer (`msg.sender` is bound into the hash).

3. **Judge / finalize** — only successfully revealed answers are eligible for AI
   judging and for winning the reward.

## Why the commitment binds four things

| Field        | Why it is in the hash                                                        |
|--------------|-----------------------------------------------------------------------------|
| `answer`     | The thing being committed to.                                               |
| `salt`       | Random blinding factor so the hash cannot be guessed from a known answer.   |
| `msg.sender` | Binds the commitment to one address — you cannot reveal another person's answer as your own. |
| `bountyId`   | Scopes the commitment to one bounty — a commitment cannot be replayed across bounties. |

`abi.encode` (not `abi.encodePacked`) is used so that the dynamic `string`
cannot collide with adjacent fields.

## Lifecycle / state machine

```
                 createBounty(reward, submissionDeadline, revealDeadline)
                                     │
              ┌──────────────────────▼───────────────────────┐
   COMMIT     │  submitCommitment(bountyId, commitment)       │  now < submissionDeadline
   PHASE      │  - stores only the hash                       │
              └──────────────────────┬───────────────────────┘
                                     │  block.timestamp reaches submissionDeadline
              ┌──────────────────────▼───────────────────────┐
   REVEAL     │  revealAnswer(bountyId, answer, salt)         │  submissionDeadline ≤ now < revealDeadline
   PHASE      │  - keccak check, stores plaintext, revealed=1 │
              └──────────────────────┬───────────────────────┘
                                     │  block.timestamp reaches revealDeadline
              ┌──────────────────────▼───────────────────────┐
   JUDGE      │  judgeAll(bountyId, llmInput)   [owner only]  │  now ≥ revealDeadline
              │  - runs AI over revealed answers only         │
              └──────────────────────┬───────────────────────┘
                                     │
              ┌──────────────────────▼───────────────────────┐
   FINALIZE   │  finalizeWinner(bountyId, winnerIndex)        │  winner must be revealed
              │  - pays reward to the winning submitter        │
              └───────────────────────────────────────────────┘
```

## Required functions (interface)

```solidity
// Phase 1 — commit only a hash (now < submissionDeadline)
function submitCommitment(uint256 bountyId, bytes32 commitment) external;

// Phase 2 — reveal plaintext + salt (submissionDeadline ≤ now < revealDeadline)
//           reverts unless keccak256(abi.encode(answer, salt, msg.sender, bountyId)) == commitment
function revealAnswer(uint256 bountyId, string calldata answer, bytes32 salt) external;

// Phase 3 — owner runs batch AI judging over the revealed answers (now ≥ revealDeadline)
function judgeAll(uint256 bountyId, bytes calldata llmInput) external;

// Phase 4 — owner finalizes and pays the winner (winner must be revealed)
function finalizeWinner(uint256 bountyId, uint256 winnerIndex) external;
```

Supporting functions: `createBounty(title, rubric, submissionDeadline,
revealDeadline)` (payable, funds the reward), plus view helpers
`getBounty`, `getSubmission`, and `computeCommitment(...)` so a client can build
the exact commitment the contract expects.

## How a participant uses it (client flow)

1. Write your `answer`.
2. Generate a **random 32-byte `salt`** and keep it secret (e.g. `crypto.getRandomValues` / `viem`'s `keccak256(randomBytes)`).
3. Compute `commitment = keccak256(abi.encode(answer, salt, yourAddress, bountyId))`
   (or call `computeCommitment(answer, salt, yourAddress, bountyId)` off-chain via a static call).
4. Call `submitCommitment(bountyId, commitment)` before `submissionDeadline`.
5. After `submissionDeadline`, call `revealAnswer(bountyId, answer, salt)` before `revealDeadline`.
6. **Keep your `salt`.** If you lose it or never reveal, your answer is forfeit — it can never be judged or win.

## Security properties

- **No copying during submission:** only hashes are on-chain during the commit phase.
- **No answer-swapping:** the answer is bound by the hash; changing it fails the reveal check.
- **No identity theft:** `msg.sender` is in the hash, so you can only reveal your own commitment.
- **No cross-bounty replay:** `bountyId` is in the hash.
- **Judging cannot see hidden answers:** `judgeAll` is gated to `now ≥ revealDeadline` and only revealed answers are eligible.
- **Non-reveal = forfeit:** an unrevealed commitment can never be judged or win the reward.

See `TEST_PLAN.md` for the reveal-case test matrix, `ARCHITECTURE.md` for the
on-chain/off-chain data-flow and threat model, and `REFLECTION.md` for the
reflection answer.
