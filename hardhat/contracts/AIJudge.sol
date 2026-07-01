// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;

    function depositFor(address user, uint256 lockDuration) external payable;

    function withdraw(uint256 amount) external;

    function balanceOf(address) external view returns (uint256);

    function lockUntil(address) external view returns (uint256);
}

/// @title AiJudge — commit-reveal bounty board with AI judging
/// @notice Answers are hidden during the submission phase so participants cannot
///         copy and out-bid one another. Each participant first submits a
///         `keccak256(abi.encode(answer, salt, msg.sender, bountyId))` commitment.
///         After the submission deadline they reveal the plaintext `answer` and
///         `salt`; the contract recomputes the hash and only accepts a matching
///         reveal. Only revealed answers are eligible for judging and winning.
contract AiJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    struct Submission {
        address submitter;
        bytes32 commitment; // hash submitted during the commit phase
        string answer; // empty until a valid reveal
        bool revealed; // true once the plaintext has been revealed & verified
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline; // commit phase ends here
        uint256 revealDeadline; // reveal phase ends here; judging opens after
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        uint256 revealedCount;
        Submission[] submissions;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    /// @dev Flat, memory-friendly view of a bounty (excludes the submissions array).
    struct BountyView {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 submissionDeadline;
        uint256 revealDeadline;
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        uint256 revealedCount;
        uint256 submissionCount;
    }

    mapping(uint256 => Bounty) public bounties;

    // bountyId => submitter => (submissionIndex + 1). 0 means "no commitment".
    mapping(uint256 => mapping(address => uint256)) private commitmentSlot;

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 submissionDeadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bountyId > 0 && bountyId < nextBountyId, "bounty does not exist");
        _;
    }

    /// @notice Create a bounty funded with `msg.value`.
    /// @param submissionDeadline unix ts after which no new commitments are accepted
    /// @param revealDeadline unix ts after which no reveals are accepted (judging opens)
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward must be greater than 0");
        require(submissionDeadline > block.timestamp, "submission deadline passed");
        require(revealDeadline > submissionDeadline, "reveal must follow submission");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];

        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.submissionDeadline = submissionDeadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(
            bountyId,
            msg.sender,
            title,
            msg.value,
            submissionDeadline,
            revealDeadline
        );
    }

    /// @notice Phase 1 — submit a commitment hash only. The plaintext stays off-chain.
    /// @dev commitment MUST equal keccak256(abi.encode(answer, salt, msg.sender, bountyId)).
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp < bounty.submissionDeadline, "submission phase over");
        require(commitment != bytes32(0), "empty commitment");
        require(commitmentSlot[bountyId][msg.sender] == 0, "already committed");
        require(bounty.submissions.length < MAX_SUBMISSIONS, "max submissions reached");

        bounty.submissions.push(
            Submission({
                submitter: msg.sender,
                commitment: commitment,
                answer: "",
                revealed: false
            })
        );

        uint256 submissionIndex = bounty.submissions.length - 1;
        commitmentSlot[bountyId][msg.sender] = submissionIndex + 1;

        emit CommitmentSubmitted(bountyId, submissionIndex, msg.sender, commitment);
    }

    /// @notice Phase 2 — reveal the plaintext answer + salt. Verified against the commitment.
    /// @dev Only callable after the submission deadline and before the reveal deadline.
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.submissionDeadline, "submission phase not over");
        require(block.timestamp < bounty.revealDeadline, "reveal phase over");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        uint256 slot = commitmentSlot[bountyId][msg.sender];
        require(slot != 0, "no commitment");

        Submission storage submission = bounty.submissions[slot - 1];
        require(!submission.revealed, "already revealed");

        bytes32 expected = keccak256(
            abi.encode(answer, salt, msg.sender, bountyId)
        );
        require(expected == submission.commitment, "commitment mismatch");

        submission.answer = answer;
        submission.revealed = true;
        bounty.revealedCount++;

        emit AnswerRevealed(bountyId, slot - 1, msg.sender);
    }

    /// @notice Phase 3 — owner runs AI judging over the revealed answers.
    /// @dev Only revealed answers should be included by the off-chain `llmInput` builder.
    ///      Judging is gated to the post-reveal window so hidden answers can never be judged.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp >= bounty.revealDeadline, "reveal phase not over");
        require(!bounty.judged, "already judged");
        require(bounty.revealedCount > 0, "no revealed answers to judge");

        bytes memory output = _executePrecompile(address(this), llmInput);
        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));
        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /// @notice Phase 4 — owner finalizes the winner and pays out the reward.
    /// @dev The winning submission MUST have been revealed.
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not yet judged");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid winner index");

        Submission storage winningSubmission = bounty.submissions[winnerIndex];
        require(winningSubmission.revealed, "winner not revealed");

        bounty.winnerIndex = winnerIndex;
        bounty.finalized = true;

        (bool ok, ) = payable(winningSubmission.submitter).call{
            value: bounty.reward
        }("");
        require(ok, "reward transfer failed");

        emit WinnerFinalized(
            bountyId,
            winnerIndex,
            winningSubmission.submitter,
            bounty.reward
        );
    }

    /// @notice Convenience helper so clients can build the exact commitment consistently.
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(answer, salt, submitter, bountyId));
    }

    function getBounty(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (BountyView memory view_) {
        Bounty storage bounty = bounties[bountyId];

        view_ = BountyView({
            owner: bounty.owner,
            title: bounty.title,
            rubric: bounty.rubric,
            reward: bounty.reward,
            submissionDeadline: bounty.submissionDeadline,
            revealDeadline: bounty.revealDeadline,
            judged: bounty.judged,
            finalized: bounty.finalized,
            aiReview: bounty.aiReview,
            winnerIndex: bounty.winnerIndex,
            revealedCount: bounty.revealedCount,
            submissionCount: bounty.submissions.length
        });
    }

    /// @notice Returns a single submission. `answer` is empty until it has been revealed.
    function getSubmission(
        uint256 bountyId,
        uint256 submissionIndex
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            bytes32 commitment,
            string memory answer,
            bool revealed
        )
    {
        Bounty storage bounty = bounties[bountyId];
        require(
            submissionIndex < bounty.submissions.length,
            "submission index out of bounds"
        );
        Submission storage submission = bounty.submissions[submissionIndex];
        return (
            submission.submitter,
            submission.commitment,
            submission.answer,
            submission.revealed
        );
    }
}
