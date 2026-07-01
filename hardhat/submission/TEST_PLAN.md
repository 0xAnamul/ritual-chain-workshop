# Test Plan — Commit-Reveal Bounty (focus on reveal cases)

## Goal

Prove that (a) answers are unreadable on-chain during the commit phase, (b) the
reveal check accepts exactly the correct `(answer, salt, sender, bountyId)` and
rejects everything else, and (c) only revealed answers can be judged or win.

## Fixtures / setup

- Actors: `owner` (creates & funds the bounty), `alice`, `bob`, `carol` (participants), `mallory` (attacker).
- Deploy the contract. `owner` calls
  `createBounty("Q", "rubric", submissionDeadline = t0 + 1h, revealDeadline = t0 + 2h)` with `msg.value = 1 ether`.
- Helper: `commit(answer, salt, who, id) = keccak256(abi.encode(answer, salt, who, id))`.
- Time control (Solidity/forge): `vm.warp(ts)`; sender control: `vm.prank(addr)`;
  expected reverts: `vm.expectRevert("<reason>")`.

Phase windows for `bountyId = 1`:
`COMMIT: t < t0+1h` · `REVEAL: t0+1h ≤ t < t0+2h` · `JUDGE: t ≥ t0+2h`.

---

## A. Commit phase

| # | Case | Action | Expected |
|---|------|--------|----------|
| A1 | Happy commit | `alice` commits `commit("blue", saltA, alice, 1)` in commit window | success; `CommitmentSubmitted` event; `getSubmission` shows the hash, empty `answer`, `revealed=false` |
| A2 | **Answer is hidden** | after A1, read `getSubmission(1, 0)` | `answer == ""`, only the hash is stored (no plaintext anywhere on-chain) |
| A3 | Double commit by same address | `alice` commits again | revert `"already committed"` |
| A4 | Empty commitment | commit `bytes32(0)` | revert `"empty commitment"` |
| A5 | Commit after deadline | `vm.warp(t0+1h)`, then `bob` commits | revert `"submission phase over"` |
| A6 | Commit on non-existent bounty | `submitCommitment(999, h)` | revert `"bounty does not exist"` |
| A7 | Max submissions | 10 distinct addresses commit, then an 11th commits | 11th reverts `"max submissions reached"` |

---

## B. Reveal phase — the core cases

Precondition for B: `alice` committed `commit("blue", saltA, alice, 1)` and
`bob` committed `commit("green", saltB, bob, 1)` during the commit window.
Then `vm.warp(t0 + 1h)` to enter the reveal window.

| # | Case | Action | Expected |
|---|------|--------|----------|
| B1 | **Happy reveal** | `alice` calls `revealAnswer(1, "blue", saltA)` | success; `AnswerRevealed` event; `getSubmission(1,0)` now returns `answer="blue"`, `revealed=true`; `revealedCount == 1` |
| B2 | **Wrong salt** | `alice` calls `revealAnswer(1, "blue", saltWRONG)` | revert `"commitment mismatch"` |
| B3 | **Wrong answer (same salt)** | `alice` calls `revealAnswer(1, "red", saltA)` | revert `"commitment mismatch"` |
| B4 | **Identity binding** | `mallory` (who saw alice's plaintext) calls `revealAnswer(1, "blue", saltA)` | revert — `mallory` has `"no commitment"` (and even if she committed, the hash uses her `msg.sender`, so it cannot match alice's commitment) |
| B5 | **Reveal too early** | in commit window (`t < t0+1h`), `alice` reveals | revert `"submission phase not over"` |
| B6 | **Reveal too late** | `vm.warp(t0+2h)`, `alice` reveals | revert `"reveal phase over"` |
| B7 | Double reveal | `alice` reveals correctly (B1), then reveals again | second call reverts `"already revealed"` |
| B8 | Reveal without commit | `carol` (never committed) reveals | revert `"no commitment"` |
| B9 | Over-length answer | reveal an answer with `bytes(answer).length > MAX_ANSWER_LENGTH` | revert `"answer too long"` |
| B10 | Two participants reveal | `alice` (B1) and `bob` both reveal correctly | both succeed; `revealedCount == 2` |
| B11 | Cross-bounty replay | commitment built with `bountyId=2` used to reveal on `bountyId=1` | revert `"commitment mismatch"` (bountyId is in the hash) |

---

## C. Judging gate

Precondition: `alice` revealed; `bob` committed but **did not** reveal.

| # | Case | Action | Expected |
|---|------|--------|----------|
| C1 | Judge before reveal window closes | `vm.warp(t0+1h)`, `owner` calls `judgeAll` | revert `"reveal phase not over"` |
| C2 | Judge by non-owner | `vm.warp(t0+2h)`, `mallory` calls `judgeAll` | revert `"not bounty owner"` |
| C3 | Judge with zero reveals | a bounty where nobody revealed; `owner` calls `judgeAll` | revert `"no revealed answers to judge"` |
| C4 | Judge success path | `vm.warp(t0+2h)`, `owner` calls `judgeAll` with valid `llmInput` | `judged=true`, `AllAnswersJudged` emitted (see note) |

> **Note on C4:** `judgeAll` invokes a Ritual precompile for AI inference, which
> does not exist on a local EVM. The success path is exercised on Ritual chain /
> with a precompile mock; on a plain local EVM only the **guard reverts**
> (C1–C3, which revert *before* the precompile call) are asserted.

---

## D. Finalize

Precondition: bounty judged; `alice` revealed (index 0); `bob` did not reveal (index 1).

| # | Case | Action | Expected |
|---|------|--------|----------|
| D1 | Finalize a revealed winner | `owner` calls `finalizeWinner(1, 0)` | success; reward transferred to `alice`; `WinnerFinalized` emitted; `finalized=true` |
| D2 | **Finalize an un-revealed submission** | `owner` calls `finalizeWinner(1, 1)` (bob never revealed) | revert `"winner not revealed"` — hidden answers can never win |
| D3 | Finalize before judging | fresh judged=false bounty | revert `"not yet judged"` |
| D4 | Double finalize | `finalizeWinner(1,0)` twice | second reverts `"already finalized"` |
| D5 | Invalid index | `finalizeWinner(1, 99)` | revert `"invalid winner index"` |
| D6 | Finalize by non-owner | `mallory` finalizes | revert `"not bounty owner"` |

---

## E. Property / fuzz ideas (optional, higher assurance)

- **Fuzz reveal correctness:** for random `(answer, salt)`, `revealAnswer` succeeds
  iff the caller committed `keccak256(abi.encode(answer, salt, caller, id))`; any
  mutation of any field makes it revert.
- **Invariant:** `revealedCount == number of submissions with revealed == true`.
- **Invariant:** `finalizeWinner` only ever pays a submission whose `revealed == true`.

## How to run

Solidity tests (forge-std cheatcodes, cleanest for time-warp + prank):

```bash
npx hardhat test solidity
```

TypeScript/viem integration tests (for event/emission assertions):

```bash
npx hardhat test nodejs
```
