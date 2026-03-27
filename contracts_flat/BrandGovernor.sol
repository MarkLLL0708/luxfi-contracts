// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title BrandGovernor
 * @dev Fixes: snapshot balance locked at vote time, timelock minimum 1 hour
 */
contract BrandGovernor is Ownable, Pausable, ReentrancyGuard {
    IERC20 public luxfiToken;

    enum ProposalStatus { Active, Passed, Rejected, Cancelled }
    enum ProposalType { ProductDecision, FlavorVote, StoreLocation, LimitedEdition, BrandCollab }

    struct Proposal {
        uint256 brandId;
        string title;
        string description;
        ProposalType proposalType;
        ProposalStatus status;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 startTime;
        uint256 endTime;
        address proposer;
        uint256 snapshotBlock;
        uint256 quorum;
        uint256 timelockEnd;
    }

    uint256 public proposalCount;
    uint256 public constant MIN_TOKENS_TO_PROPOSE  = 1000 * 1e18;
    uint256 public constant MIN_TOKENS_TO_VOTE     = 100  * 1e18;
    uint256 public constant VOTING_PERIOD          = 7 days;
    uint256 public constant MIN_BLOCKS_BEFORE_VOTE = 100;
    uint256 public constant MIN_HOLDING_BEFORE_PROPOSE = 7 days;

    uint256 public quorumThreshold = 1000 * 1e18;
    uint256 public timelockDelay   = 2 days;

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool))    public hasVoted;
    mapping(uint256 => mapping(address => uint256)) public snapshotBalance;
    mapping(uint256 => mapping(address => uint256)) public balanceAtSnapshot;

    mapping(address => uint256) public tokenAcquiredBlock;
    mapping(address => uint256) public tokenAcquiredTime;

    event ProposalCreated(uint256 indexed proposalId, uint256 indexed brandId, string title, address proposer);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalFinalized(uint256 indexed proposalId, ProposalStatus status);
    event QuorumUpdated(uint256 newQuorum);
    event TimelockUpdated(uint256 newDelay);

    constructor(address _luxfiToken) Ownable(msg.sender) {
        require(_luxfiToken != address(0), "Invalid token address");
        luxfiToken = IERC20(_luxfiToken);
    }

    function recordTokenAcquisition(address account) external {
        require(msg.sender == address(luxfiToken), "Only token contract");
        if (tokenAcquiredBlock[account] == 0) {
            tokenAcquiredBlock[account] = block.number;
            tokenAcquiredTime[account] = block.timestamp;
        }
    }

    function createProposal(uint256 brandId, string calldata title, string calldata description, ProposalType proposalType) external whenNotPaused returns (uint256) {
        require(luxfiToken.balanceOf(msg.sender) >= MIN_TOKENS_TO_PROPOSE, "Not enough tokens");
        require(bytes(title).length > 0 && bytes(title).length <= 200, "Invalid title");
        require(bytes(description).length <= 2000, "Description too long");
        require(block.timestamp - tokenAcquiredTime[msg.sender] >= MIN_HOLDING_BEFORE_PROPOSE, "Must hold tokens 7 days before proposing");

        uint256 id = proposalCount++;
        proposals[id] = Proposal({
            brandId: brandId, title: title, description: description, proposalType: proposalType,
            status: ProposalStatus.Active, votesFor: 0, votesAgainst: 0,
            startTime: block.timestamp, endTime: block.timestamp + VOTING_PERIOD,
            proposer: msg.sender, snapshotBlock: block.number, quorum: quorumThreshold, timelockEnd: 0
        });

        emit ProposalCreated(id, brandId, title, msg.sender);
        return id;
    }

    function vote(uint256 proposalId, bool support) external nonReentrant whenNotPaused {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Active, "Not active");
        require(block.timestamp >= p.startTime, "Voting not started");
        require(block.timestamp <= p.endTime, "Voting ended");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        require(tokenAcquiredBlock[msg.sender] < p.snapshotBlock, "Tokens acquired after proposal");
        require(block.number >= tokenAcquiredBlock[msg.sender] + MIN_BLOCKS_BEFORE_VOTE, "Must wait minimum blocks");
        require(block.timestamp - tokenAcquiredTime[msg.sender] >= 7 days, "Must hold tokens 7 days before voting");

        uint256 weight = luxfiToken.balanceOf(msg.sender);
        require(weight >= MIN_TOKENS_TO_VOTE, "Not enough tokens");

        snapshotBalance[proposalId][msg.sender] = weight;
        balanceAtSnapshot[proposalId][msg.sender] = weight;
        hasVoted[proposalId][msg.sender] = true;

        if (support) p.votesFor += weight;
        else p.votesAgainst += weight;

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    function finalizeProposal(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Active, "Not active");
        require(block.timestamp > p.endTime, "Voting still active");

        uint256 totalVotes = p.votesFor + p.votesAgainst;
        if (totalVotes < p.quorum) {
            p.status = ProposalStatus.Rejected;
            emit ProposalFinalized(proposalId, ProposalStatus.Rejected);
            return;
        }

        if (p.votesFor > p.votesAgainst) {
            p.status = ProposalStatus.Passed;
            p.timelockEnd = block.timestamp + timelockDelay;
        } else {
            p.status = ProposalStatus.Rejected;
        }
        emit ProposalFinalized(proposalId, p.status);
    }

    function cancelProposal(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(msg.sender == p.proposer || msg.sender == owner(), "Not authorized");
        require(p.status == ProposalStatus.Active, "Not active");
        p.status = ProposalStatus.Cancelled;
        emit ProposalFinalized(proposalId, ProposalStatus.Cancelled);
    }

    function setQuorum(uint256 newQuorum) external onlyOwner { require(newQuorum > 0, "Zero quorum"); quorumThreshold = newQuorum; emit QuorumUpdated(newQuorum); }
    function setTimelockDelay(uint256 delay) external onlyOwner { require(delay >= 1 hours, "Timelock too short"); require(delay <= 7 days, "Timelock too long"); timelockDelay = delay; emit TimelockUpdated(delay); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function getProposal(uint256 proposalId) external view returns (Proposal memory) { return proposals[proposalId]; }
    function getVotingPower(uint256 proposalId, address voter) external view returns (uint256) {
        if (hasVoted[proposalId][voter]) return snapshotBalance[proposalId][voter];
        return luxfiToken.balanceOf(voter);
    }
    function getAllProposals() external view returns (Proposal[] memory) {
        Proposal[] memory list = new Proposal[](proposalCount);
        for (uint256 i; i < proposalCount; i++) list[i] = proposals[i];
        return list;
    }
}
