# Reflection

**"What should be public, what should stay hidden, and what should be decided by
AI versus by a human in a bounty system?"**

In a bounty system the *rules of the game* should be fully public — the title,
rubric, reward amount, deadlines, and the list of participant addresses and their
commitment hashes — because that transparency is what makes the process auditable
and trustless. What must stay hidden, at least until the submission window
closes, is the *content* of each answer, so that no participant can watch a
rival's work and plagiarize an improved version; commit-reveal enforces this by
storing only a salted hash on-chain during the commit phase and revealing the
plaintext afterward. Once the reveal deadline passes it is fine — even desirable
— for the answers to become public, since the copying risk is gone and openness
aids verification. The split between AI and humans should follow the difference
between *scalable evaluation* and *accountable authority*: an AI is well suited to
batch-scoring many answers against an objective rubric consistently and cheaply,
producing a ranked shortlist and written rationale. A human — the bounty owner —
should retain final authority over accepting that ranking, resolving ties or edge
cases, and releasing the funds, because paying out real money is an irreversible,
high-stakes action that benefits from human accountability and a check against
model error or gaming. In short: make the *process and commitments* public, keep
*answer contents* hidden until reveal, let *AI do the heavy, repeatable grading*,
and let a *human own the final, irreversible payout decision*.
