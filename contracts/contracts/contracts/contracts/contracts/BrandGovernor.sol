// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
}

uint256 public proposalCount;
uint256 public constant MIN_TOKENS_TO_PROPOSE = 1000 * 1e18;
uint256 public constant MIN_TOKENS_TO_VOTE = 100 * 1e18;
uint256 public constant VOTING_PERIOD = 7 days;

mapping(uint256 => Proposal) public proposals;
mapping(uint256 => mapping(address => bool)) public hasVoted;
mapping(uint256 => mapping(address => uint256)) public voteWeight;

event ProposalCreated(uint256 indexed proposalId, uint256 indexed brandId, string title, address proposer);
event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
event ProposalFinalized(uint256 indexed proposalId, ProposalStatus status);

constructor(address _luxfiToken) Ownable(msg.sender) {
    luxfiToken = IERC20(_luxfiToken);
}

function createProposal(uint256 brandId, string calldata title, string calldata description, ProposalType proposalType) external whenNotPaused returns (uint256) {
    require(luxfiToken.balanceOf(msg.sender) >= MIN_TOKENS_TO_PROPOSE, "Not enough tokens to propose");
    require(bytes(title).length > 0, "Empty title");
    uint256 id = proposalCount++;
    proposals[id] = Proposal(
        brandId, title, description,
        proposalType, ProposalStatus.Active,
        0, 0, block.timestamp,
        block.timestamp + VOTING_PERIOD,
        msg.sender
    );
    emit ProposalCreated(id, brandId, title, msg.sender);
    return id;
}

function vote(uint256 proposalId, bool support) external nonReentrant whenNotPaused {
    Proposal storage p = proposals[proposalId];
    require(p.status == ProposalStatus.Active, "Not active");
    require(block.timestamp <= p.endTime, "Voting ended");
    require(!hasVoted[proposalId][msg.sender], "Already voted");
    uint256 weight = luxfiToken.balanceOf(msg.sender);
    require(weight >= MIN_TOKENS_TO_VOTE, "Not enough tokens to vote");
    hasVoted[proposalId][msg.sender] = true;
    voteWeight[proposalId][msg.sender] = weight;
    if (support) {
        p.votesFor += weight;
    } else {
        p.votesAgainst += weight;
    }
    emit VoteCast(proposalId, msg.sender, support, weight);
}

function finalizeProposal(uint256 proposalId) external {
    Proposal storage p = proposals[proposalId];
    require(p.status == ProposalStatus.Active, "Not active");
    require(block.timestamp > p.endTime, "Voting still active");
    if (p.votesFor > p.votesAgainst) {
        p.status = ProposalStatus.Passed;
    } else {
        p.status = ProposalStatus.Rejected;
    }
    emit ProposalFinalized(proposalId, p.status);
}

function cancelProposal(uint256 proposalId) external onlyOwner {
    proposals[proposalId].status = ProposalStatus.Cancelled;
    emit ProposalFinalized(proposalId, ProposalStatus.Cancelled);
}

function getProposal(uint256 proposalId) external view returns (Proposal memory) {
    return proposals[proposalId];
}

function getAllProposals() external view returns (Proposal[] memory) {
    Proposal[] memory list = new Proposal[](proposalCount);
    for (uint256 i; i < proposalCount; i++) {
        list[i] = proposals[i];
    }
    return list;
}

function pause() external onlyOwner { _pause(); }
function unpause() external onlyOwner { _unpause(); }
}
