// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title EcoGovernor
 * @dev FIX ATK-04: snapshot-based voting — prevents double voting via token transfer
 */
contract EcoGovernor is Ownable, Pausable, ReentrancyGuard {
    IERC20 public luxfiToken;

    enum ProposalStatus { Active, Passed, Rejected, Cancelled, Executed }
    enum ProposalType { FeeChange, NewBrandCategory, ProtocolUpgrade, TreasuryAllocation, PartnershipApproval }

    struct EcoProposal {
        string title;
        string description;
        ProposalType proposalType;
        ProposalStatus status;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 startTime;
        uint256 endTime;
        uint256 quorumRequired;
        address proposer;
        bool executed;
        uint256 snapshotBlock;
    }

    uint256 public proposalCount;
    uint256 public constant MIN_TOKENS_TO_PROPOSE   = 10000 * 1e18;
    uint256 public constant MIN_TOKENS_TO_VOTE      = 100   * 1e18;
    uint256 public constant VOTING_PERIOD           = 14 days;
    uint256 public constant MIN_HOLDING_BEFORE_VOTE = 7 days;

    mapping(uint256 => EcoProposal) public proposals;
    mapping(uint256 => mapping(address => bool))    public hasVoted;
    mapping(uint256 => mapping(address => uint256)) public voteWeight;
    mapping(address => uint256) public tokenAcquiredBlock;
    mapping(address => uint256) public tokenAcquiredTime;

    event EcoProposalCreated(uint256 indexed proposalId, string title, ProposalType proposalType, address proposer);
    event EcoVoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event EcoProposalFinalized(uint256 indexed proposalId, ProposalStatus status);
    event EcoProposalExecuted(uint256 indexed proposalId);
    event TokenAcquisitionRecorded(address indexed account, uint256 blockNumber, uint256 timestamp);

    constructor(address _luxfiToken) Ownable(msg.sender) {
        require(_luxfiToken != address(0), "Invalid token");
        luxfiToken = IERC20(_luxfiToken);
    }

    function recordTokenAcquisition(address account) external {
        require(msg.sender == address(luxfiToken), "Only token contract");
        if (tokenAcquiredBlock[account] == 0) {
            tokenAcquiredBlock[account] = block.number;
            tokenAcquiredTime[account]  = block.timestamp;
            emit TokenAcquisitionRecorded(account, block.number, block.timestamp);
        }
    }

    function createProposal(
        string calldata title,
        string calldata description,
        ProposalType proposalType,
        uint256 quorumRequired
    ) external whenNotPaused returns (uint256) {
        require(luxfiToken.balanceOf(msg.sender) >= MIN_TOKENS_TO_PROPOSE, "Not enough tokens");
        require(bytes(title).length > 0, "Empty title");
        uint256 id = proposalCount++;
        proposals[id] = EcoProposal({
            title:          title,
            description:    description,
            proposalType:   proposalType,
            status:         ProposalStatus.Active,
            votesFor:       0,
            votesAgainst:   0,
            startTime:      block.timestamp,
            endTime:        block.timestamp + VOTING_PERIOD,
            quorumRequired: quorumRequired,
            proposer:       msg.sender,
            executed:       false,
            snapshotBlock:  block.number
        });
        emit EcoProposalCreated(id, title, proposalType, msg.sender);
        return id;
    }

    function vote(uint256 proposalId, bool support) external nonReentrant whenNotPaused {
        EcoProposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Active, "Not active");
        require(block.timestamp <= p.endTime, "Voting ended");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        require(tokenAcquiredBlock[msg.sender] != 0, "Acquisition not recorded");
        require(tokenAcquiredBlock[msg.sender] < p.snapshotBlock, "Tokens acquired after proposal");
        require(block.timestamp - tokenAcquiredTime[msg.sender] >= MIN_HOLDING_BEFORE_VOTE, "Must hold 7 days");

        uint256 weight = luxfiToken.balanceOf(msg.sender);
        require(weight >= MIN_TOKENS_TO_VOTE, "Not enough tokens");
        hasVoted[proposalId][msg.sender] = true;
        voteWeight[proposalId][msg.sender] = weight;
        if (support) { p.votesFor += weight; } else { p.votesAgainst += weight; }
        emit EcoVoteCast(proposalId, msg.sender, support, weight);
    }

    function finalizeProposal(uint256 proposalId) external {
        EcoProposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Active, "Not active");
        require(block.timestamp > p.endTime, "Voting still active");
        uint256 totalVotes = p.votesFor + p.votesAgainst;
        require(totalVotes >= p.quorumRequired, "Quorum not reached");
        p.status = p.votesFor > p.votesAgainst ? ProposalStatus.Passed : ProposalStatus.Rejected;
        emit EcoProposalFinalized(proposalId, p.status);
    }

    function executeProposal(uint256 proposalId) external onlyOwner {
        EcoProposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Passed, "Not passed");
        require(!p.executed, "Already executed");
        p.executed = true;
        p.status = ProposalStatus.Executed;
        emit EcoProposalExecuted(proposalId);
    }

    function cancelProposal(uint256 proposalId) external onlyOwner {
        proposals[proposalId].status = ProposalStatus.Cancelled;
        emit EcoProposalFinalized(proposalId, ProposalStatus.Cancelled);
    }

    function getProposal(uint256 proposalId) external view returns (EcoProposal memory) { return proposals[proposalId]; }
    function getAllProposals() external view returns (EcoProposal[] memory) {
        EcoProposal[] memory list = new EcoProposal[](proposalCount);
        for (uint256 i; i < proposalCount; i++) list[i] = proposals[i];
        return list;
    }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
