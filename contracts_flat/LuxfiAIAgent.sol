// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";

interface ILuxfiMintable {
    function mint(address to, uint256 amount) external;
}

/**
 * @title LuxfiAIAgent
 * @notice Web 4.0 AI Agent — autonomous economic participant on BSC
 * @dev Rewards: Fresh LUXFI minted + BNB by difficulty + NFT badge
 */
contract LuxfiAIAgent is Ownable, AccessControl, Pausable, ReentrancyGuard, ERC721URIStorage {
    using SafeERC20 for IERC20;

    // ─── WEB 4.0 IDENTITY ────────────────────────────────
    bytes32 public immutable AGENT_ID;
    string public agentName    = "LUXFI COMMAND AI";
    string public agentVersion = "4.0.0";
    uint256 public immutable BIRTH_BLOCK;
    uint256 public immutable BIRTH_TIME;

    // ─── ROLES ───────────────────────────────────────────
    bytes32 public constant AI_ORACLE_ROLE       = keccak256("AI_ORACLE_ROLE");
    bytes32 public constant MISSION_CREATOR_ROLE = keccak256("MISSION_CREATOR_ROLE");

    // ─── TOKEN ───────────────────────────────────────────
    ILuxfiMintable public luxfiToken;
    IERC20 public usdtToken;

    // ─── NFT BADGE ───────────────────────────────────────
    uint256 public badgeTokenId;

    // Badge tier URIs — set by admin
    mapping(uint8 => string) public badgeURIs;

    // ─── DIFFICULTY REWARD TIERS ─────────────────────────
    struct RewardTier {
        uint256 luxfiAmount;
        uint256 bnbAmount;
        string  badgeName;
        uint8   badgeTier;
    }

    mapping(uint8 => RewardTier) public rewardTiers;

    // ─── MISSION STRUCTS ─────────────────────────────────
    struct AIMission {
        bytes32     missionId;
        string      codename;
        string      briefing;
        string[]    requirements;
        uint256     rewardBNB;
        uint256     rewardLUXFI;
        uint256     stakeRequired;
        uint256     createdAt;
        uint256     deadline;
        uint256     maxAgents;
        uint256     claimedCount;
        MissionStatus status;
        MissionType missionType;
        string      city;
        string      brandName;
        uint8       difficulty;
        bool        aiGenerated;
        bytes32     aiSignature;
    }

    enum MissionStatus { ACTIVE, COMPLETED, CANCELLED, EXPIRED }
    enum MissionType {
        SPOT_IT, FOUNDER_DROP, MYSTERY_SHOP, SIGNAL_BOOST,
        FIRST_SIGHTING, AI_VERIFY, BRAND_AUDIT, RIVAL_INTEL
    }

    struct MissionClaim {
        bytes32     claimId;
        bytes32     missionId;
        address     agent;
        uint256     stakedAmount;
        uint256     submittedAt;
        uint256     approvedAt;
        ClaimStatus status;
        string      intelData;
        uint256     aiScore;
        bytes32     proofHash;
        bool        aiVerified;
        uint256     badgeTokenId;
    }

    enum ClaimStatus { PENDING, SUBMITTED, AI_REVIEWING, APPROVED, REJECTED, DISPUTED }

    // ─── AGENT PROFILE ───────────────────────────────────
    struct AgentProfile {
        address       wallet;
        bytes32       agentId;
        string        codename;
        uint256       xp;
        uint256       missionsCompleted;
        uint256       missionsAttempted;
        uint256       totalEarned;
        uint256       totalStaked;
        uint256       joinedAt;
        ClearanceLevel clearance;
        bool          isBlacklisted;
        uint256       reputationScore;
        uint256[]     badgesEarned;
    }

    enum ClearanceLevel { ROOKIE, OPERATIVE, SPECIALIST, GHOST, PHANTOM }

    // ─── STORAGE ─────────────────────────────────────────
    mapping(bytes32 => AIMission)    public missions;
    mapping(bytes32 => MissionClaim) public claims;
    mapping(address => AgentProfile) public agentProfiles;
    mapping(address => bytes32[])    public agentMissions;
    mapping(bytes32 => bytes32[])    public missionClaims;
    mapping(bytes32 => bool)         public usedProofHashes;

    bytes32[] public activeMissionIds;
    uint256   public missionCount;
    uint256   public claimCount;

    // ─── ECONOMICS ───────────────────────────────────────
    uint256 public platformFeeBps = 500;
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public aiMissionBudget;
    uint256 public totalRewardsDistributed;
    uint256 public totalMissionsCreated;
    uint256 public totalMissionsCompleted;
    uint256 public minAIScore = 70;

    address public aiOracleAddress;
    mapping(bytes32 => uint256) public aiVerificationScores;

    // ─── XP REWARDS ──────────────────────────────────────
    uint256 public constant XP_ROUTINE     = 100;
    uint256 public constant XP_CLASSIFIED  = 250;
    uint256 public constant XP_EYES_ONLY   = 500;
    uint256 public constant XP_AI_VERIFY   = 150;
    uint256 public constant XP_BRAND_AUDIT = 400;

    // ─── EVENTS ──────────────────────────────────────────
    event AgentIdentityCreated(bytes32 indexed agentId, string name, uint256 birthBlock);
    event MissionCreated(bytes32 indexed missionId, string codename, bool aiGenerated);
    event MissionClaimed(bytes32 indexed missionId, bytes32 claimId, address agent);
    event ProofSubmitted(bytes32 indexed claimId, address agent, bytes32 proofHash);
    event AIVerificationComplete(bytes32 indexed claimId, uint256 score, bool approved);
    event MissionApproved(bytes32 indexed claimId, address agent, uint256 luxfiMinted, uint256 bnbSent, uint256 badgeId);
    event MissionRejected(bytes32 indexed claimId, address agent, string reason);
    event AgentLevelUp(address indexed agent, ClearanceLevel newLevel);
    event BadgeMinted(address indexed agent, uint256 tokenId, uint8 tier, string badgeName);
    event AIBudgetReceived(uint256 amount);
    event ReputationUpdated(address indexed agent, uint256 newScore);
    event RewardTierUpdated(uint8 difficulty, uint256 luxfi, uint256 bnb, string badge);

    constructor(
        address _luxfiToken,
        address _usdtToken,
        address _aiOracle,
        address _owner
    ) Ownable(_owner) ERC721("LUXFI Mission Badge", "LMBD") {
        require(_luxfiToken != address(0), "Invalid token");
        require(_aiOracle != address(0),   "Invalid oracle");

        luxfiToken      = ILuxfiMintable(_luxfiToken);
        usdtToken       = IERC20(_usdtToken);
        aiOracleAddress = _aiOracle;

        AGENT_ID = keccak256(abi.encodePacked(
            block.chainid, address(this), block.timestamp, "LUXFI_AI_AGENT_V4"
        ));
        BIRTH_BLOCK = block.number;
        BIRTH_TIME  = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE,   _owner);
        _grantRole(AI_ORACLE_ROLE,       _aiOracle);
        _grantRole(MISSION_CREATOR_ROLE, _owner);
        _grantRole(MISSION_CREATOR_ROLE, _aiOracle);

        // ─── DEFAULT REWARD TIERS ─────────────────────────
        // difficulty 1 = ROUTINE, 2 = STANDARD/PRIORITY, 3 = CRITICAL/CLASSIFIED
        rewardTiers[1] = RewardTier(100  * 1e18, 0.001 ether, "Bronze",   1);
        rewardTiers[2] = RewardTier(500  * 1e18, 0.005 ether, "Gold",     2);
        rewardTiers[3] = RewardTier(2500 * 1e18, 0.025 ether, "Diamond",  3);

        emit AgentIdentityCreated(AGENT_ID, agentName, block.number);
    }

    // ─── RECEIVE BNB ─────────────────────────────────────
    receive() external payable {
        aiMissionBudget += msg.value;
        emit AIBudgetReceived(msg.value);
    }

    // ─── SET BADGE URI ────────────────────────────────────
    function setBadgeURI(uint8 tier, string calldata uri) external onlyOwner {
        badgeURIs[tier] = uri;
    }

    // ─── SET REWARD TIER ──────────────────────────────────
    function setRewardTier(
        uint8 difficulty,
        uint256 luxfiAmount,
        uint256 bnbAmount,
        string calldata badge,
        uint8 badgeTier
    ) external onlyOwner {
        require(difficulty >= 1 && difficulty <= 3, "Invalid difficulty");
        rewardTiers[difficulty] = RewardTier(luxfiAmount, bnbAmount, badge, badgeTier);
        emit RewardTierUpdated(difficulty, luxfiAmount, bnbAmount, badge);
    }

    // ─── CREATE MISSION ───────────────────────────────────
    function createMission(
        string calldata codename,
        string calldata briefing,
        string[] calldata requirements,
        uint256 stakeRequired,
        uint256 durationDays,
        uint256 maxAgents,
        MissionType missionType,
        string calldata city,
        string calldata brandName,
        uint8 difficulty,
        bool aiGenerated,
        bytes32 aiSignature
    ) external onlyRole(MISSION_CREATOR_ROLE) whenNotPaused returns (bytes32) {
        require(bytes(codename).length > 0,            "Empty codename");
        require(durationDays >= 1 && durationDays <= 30, "Invalid duration");
        require(maxAgents >= 1 && maxAgents <= 100,    "Invalid max agents");
        require(difficulty >= 1 && difficulty <= 3,    "Invalid difficulty");

        // Reserve BNB budget for all potential agents
        RewardTier memory tier = rewardTiers[difficulty];
        uint256 totalBNBNeeded = tier.bnbAmount * maxAgents;
        require(aiMissionBudget >= totalBNBNeeded, "Insufficient BNB budget");
        aiMissionBudget -= totalBNBNeeded;

        bytes32 missionId = keccak256(abi.encodePacked(
            codename, block.timestamp, missionCount++
        ));

        missions[missionId] = AIMission({
            missionId:    missionId,
            codename:     codename,
            briefing:     briefing,
            requirements: requirements,
            rewardBNB:    tier.bnbAmount,
            rewardLUXFI:  tier.luxfiAmount,
            stakeRequired: stakeRequired,
            createdAt:    block.timestamp,
            deadline:     block.timestamp + (durationDays * 1 days),
            maxAgents:    maxAgents,
            claimedCount: 0,
            status:       MissionStatus.ACTIVE,
            missionType:  missionType,
            city:         city,
            brandName:    brandName,
            difficulty:   difficulty,
            aiGenerated:  aiGenerated,
            aiSignature:  aiSignature
        });

        activeMissionIds.push(missionId);
        totalMissionsCreated++;

        emit MissionCreated(missionId, codename, aiGenerated);
        return missionId;
    }

    // ─── REGISTER AGENT ───────────────────────────────────
    function registerAgent(string calldata codename) external whenNotPaused {
        require(agentProfiles[msg.sender].wallet == address(0), "Already registered");
        require(bytes(codename).length >= 3, "Codename too short");

        bytes32 agentId = keccak256(abi.encodePacked(
            msg.sender, block.timestamp, codename
        ));

        uint256[] memory emptyBadges;
        agentProfiles[msg.sender] = AgentProfile({
            wallet:            msg.sender,
            agentId:           agentId,
            codename:          codename,
            xp:                0,
            missionsCompleted: 0,
            missionsAttempted: 0,
            totalEarned:       0,
            totalStaked:       0,
            joinedAt:          block.timestamp,
            clearance:         ClearanceLevel.ROOKIE,
            isBlacklisted:     false,
            reputationScore:   500,
            badgesEarned:      emptyBadges
        });
    }

    // ─── CLAIM MISSION ────────────────────────────────────
    function claimMission(bytes32 missionId) external payable nonReentrant whenNotPaused {
        AIMission storage m        = missions[missionId];
        AgentProfile storage agent = agentProfiles[msg.sender];

        require(m.status == MissionStatus.ACTIVE, "Mission not active");
        require(block.timestamp < m.deadline,      "Mission expired");
        require(m.claimedCount < m.maxAgents,      "Mission full");
        require(agent.wallet != address(0),        "Not registered");
        require(!agent.isBlacklisted,              "Agent blacklisted");
        require(msg.value >= m.stakeRequired,      "Insufficient stake");
        require(agent.reputationScore >= 300,      "Reputation too low");

        bytes32 claimId = keccak256(abi.encodePacked(
            missionId, msg.sender, block.timestamp, claimCount++
        ));

        claims[claimId] = MissionClaim({
            claimId:      claimId,
            missionId:    missionId,
            agent:        msg.sender,
            stakedAmount: msg.value,
            submittedAt:  0,
            approvedAt:   0,
            status:       ClaimStatus.PENDING,
            intelData:    "",
            aiScore:      0,
            proofHash:    bytes32(0),
            aiVerified:   false,
            badgeTokenId: 0
        });

        missionClaims[missionId].push(claimId);
        agentMissions[msg.sender].push(claimId);
        m.claimedCount++;
        agent.missionsAttempted++;
        agent.totalStaked += msg.value;

        emit MissionClaimed(missionId, claimId, msg.sender);
    }

    // ─── SUBMIT PROOF ─────────────────────────────────────
    function submitProof(
        bytes32 claimId,
        string calldata intelData,
        bytes32 proofHash
    ) external whenNotPaused {
        MissionClaim storage claim = claims[claimId];
        require(claim.agent == msg.sender,           "Not your claim");
        require(claim.status == ClaimStatus.PENDING, "Wrong status");
        require(!usedProofHashes[proofHash],         "Duplicate proof");
        require(bytes(intelData).length > 0,         "Empty intel");

        AIMission storage m = missions[claim.missionId];
        require(block.timestamp < m.deadline, "Mission expired");

        usedProofHashes[proofHash] = true;
        claim.intelData   = intelData;
        claim.proofHash   = proofHash;
        claim.submittedAt = block.timestamp;
        claim.status      = ClaimStatus.SUBMITTED;

        emit ProofSubmitted(claimId, msg.sender, proofHash);
    }

    // ─── AI VERIFICATION ─────────────────────────────────
    function submitAIVerification(
        bytes32 claimId,
        uint256 score,
        bool approved,
        string calldata reason
    ) external onlyRole(AI_ORACLE_ROLE) nonReentrant {
        MissionClaim storage claim = claims[claimId];
        require(
            claim.status == ClaimStatus.SUBMITTED ||
            claim.status == ClaimStatus.AI_REVIEWING,
            "Wrong status"
        );
        require(score <= 100, "Invalid score");

        claim.aiScore    = score;
        claim.aiVerified = true;
        claim.status     = ClaimStatus.AI_REVIEWING;
        aiVerificationScores[claimId] = score;

        emit AIVerificationComplete(claimId, score, approved);

        if (approved && score >= minAIScore) {
            _approveMission(claimId);
        } else {
            _rejectMission(claimId, reason);
        }
    }

    // ─── INTERNAL APPROVE ────────────────────────────────
    function _approveMission(bytes32 claimId) internal {
        MissionClaim storage claim = claims[claimId];
        AIMission storage m        = missions[claim.missionId];
        AgentProfile storage agent = agentProfiles[claim.agent];

        // CEI — update state first
        claim.status     = ClaimStatus.APPROVED;
        claim.approvedAt = block.timestamp;

        RewardTier memory tier = rewardTiers[m.difficulty];

        // 1 — Mint fresh LUXFI tokens to agent
        uint256 luxfiReward = tier.luxfiAmount;
        luxfiToken.mint(claim.agent, luxfiReward);

        // 2 — Send BNB reward + return stake
        uint256 fee         = (tier.bnbAmount * platformFeeBps) / 10000;
        uint256 agentBNB    = tier.bnbAmount - fee + claim.stakedAmount;
        require(address(this).balance >= agentBNB, "Insufficient BNB");
        (bool bnbSent,) = payable(claim.agent).call{value: agentBNB}("");
        if (!bnbSent) {
            aiMissionBudget += tier.bnbAmount;
        }

        // 3 — Mint NFT badge
        uint256 newBadgeId = ++badgeTokenId;
        _mint(claim.agent, newBadgeId);
        if (bytes(badgeURIs[tier.badgeTier]).length > 0) {
            _setTokenURI(newBadgeId, badgeURIs[tier.badgeTier]);
        }
        claim.badgeTokenId = newBadgeId;
        agent.badgesEarned.push(newBadgeId);

        // 4 — Update agent stats
        uint256 xpEarned = _getXPForDifficulty(m.difficulty, m.missionType);
        agent.xp += xpEarned;
        agent.missionsCompleted++;
        agent.totalEarned += tier.bnbAmount + luxfiReward;

        uint256 newRep = agent.reputationScore + (claim.aiScore / 10);
        agent.reputationScore = newRep > 1000 ? 1000 : newRep;

        totalRewardsDistributed += luxfiReward;
        totalMissionsCompleted++;

        _checkLevelUp(claim.agent);

        emit BadgeMinted(claim.agent, newBadgeId, tier.badgeTier, tier.badgeName);
        emit MissionApproved(claimId, claim.agent, luxfiReward, agentBNB, newBadgeId);
        emit ReputationUpdated(claim.agent, agent.reputationScore);
    }

    // ─── INTERNAL REJECT ─────────────────────────────────
    function _rejectMission(bytes32 claimId, string memory reason) internal {
        MissionClaim storage claim = claims[claimId];
        AgentProfile storage agent = agentProfiles[claim.agent];

        claim.status = ClaimStatus.REJECTED;

        uint256 slashAmount  = claim.stakedAmount / 10;
        uint256 returnAmount = claim.stakedAmount - slashAmount;

        if (returnAmount > 0) {
            (bool success,) = payable(claim.agent).call{value: returnAmount}("");
            if (!success) aiMissionBudget += returnAmount;
        }
        aiMissionBudget += slashAmount;

        uint256 repReduction = (100 - claim.aiScore) / 5;
        if (agent.reputationScore > repReduction) {
            agent.reputationScore -= repReduction;
        } else {
            agent.reputationScore = 0;
        }

        emit MissionRejected(claimId, claim.agent, reason);
        emit ReputationUpdated(claim.agent, agent.reputationScore);
    }

    // ─── LEVEL UP ─────────────────────────────────────────
    function _checkLevelUp(address agentWallet) internal {
        AgentProfile storage agent = agentProfiles[agentWallet];
        ClearanceLevel newLevel    = agent.clearance;

        if      (agent.xp >= 10000) newLevel = ClearanceLevel.PHANTOM;
        else if (agent.xp >= 5000)  newLevel = ClearanceLevel.GHOST;
        else if (agent.xp >= 2000)  newLevel = ClearanceLevel.SPECIALIST;
        else if (agent.xp >= 500)   newLevel = ClearanceLevel.OPERATIVE;

        if (newLevel != agent.clearance) {
            agent.clearance = newLevel;
            emit AgentLevelUp(agentWallet, newLevel);
        }
    }

    // ─── XP CALCULATION ───────────────────────────────────
    function _getXPForDifficulty(
        uint8 difficulty,
        MissionType missionType
    ) internal pure returns (uint256) {
        uint256 baseXP;
        if      (difficulty == 3) baseXP = XP_EYES_ONLY;
        else if (difficulty == 2) baseXP = XP_CLASSIFIED;
        else                      baseXP = XP_ROUTINE;

        if      (missionType == MissionType.BRAND_AUDIT) baseXP = XP_BRAND_AUDIT;
        else if (missionType == MissionType.AI_VERIFY)   baseXP = XP_AI_VERIFY;

        return baseXP;
    }

    // ─── ADMIN ───────────────────────────────────────────
    function setAIOracle(address oracle) external onlyOwner {
        require(oracle != address(0), "Invalid oracle");
        _revokeRole(AI_ORACLE_ROLE, aiOracleAddress);
        aiOracleAddress = oracle;
        _grantRole(AI_ORACLE_ROLE, oracle);
    }

    function setMinAIScore(uint256 score) external onlyOwner {
        require(score <= 100, "Invalid score");
        minAIScore = score;
    }

    function setPlatformFee(uint256 feeBps) external onlyOwner {
        require(feeBps <= MAX_FEE_BPS, "Fee too high");
        platformFeeBps = feeBps;
    }

    function blacklistAgent(address agent, bool status) external onlyOwner {
        agentProfiles[agent].isBlacklisted = status;
    }

    function cancelMission(bytes32 missionId) external onlyOwner {
        missions[missionId].status = MissionStatus.CANCELLED;
    }

    function withdrawBudget(uint256 amount) external onlyOwner {
        require(amount <= aiMissionBudget, "Exceeds budget");
        aiMissionBudget -= amount;
        (bool success,) = payable(owner()).call{value: amount}("");
        require(success, "Transfer failed");
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── VIEWS ───────────────────────────────────────────
    function getMission(bytes32 missionId) external view returns (AIMission memory) {
        return missions[missionId];
    }

    function getClaim(bytes32 claimId) external view returns (MissionClaim memory) {
        return claims[claimId];
    }

    function getAgentProfile(address agent) external view returns (AgentProfile memory) {
        return agentProfiles[agent];
    }

    function getActiveMissions() external view returns (bytes32[] memory) {
        uint256 count = 0;
        for (uint256 i = 0; i < activeMissionIds.length; i++) {
            if (missions[activeMissionIds[i]].status == MissionStatus.ACTIVE &&
                block.timestamp < missions[activeMissionIds[i]].deadline) count++;
        }
        bytes32[] memory active = new bytes32[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < activeMissionIds.length; i++) {
            if (missions[activeMissionIds[i]].status == MissionStatus.ACTIVE &&
                block.timestamp < missions[activeMissionIds[i]].deadline) {
                active[idx++] = activeMissionIds[i];
            }
        }
        return active;
    }

    function getAgentBadges(address agent) external view returns (uint256[] memory) {
        return agentProfiles[agent].badgesEarned;
    }

    function getRewardTier(uint8 difficulty) external view returns (RewardTier memory) {
        return rewardTiers[difficulty];
    }

    function supportsInterface(bytes4 interfaceId)
        public view override(AccessControl, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}



