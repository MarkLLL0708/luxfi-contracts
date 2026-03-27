// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LuxfiAIAgent
 * @notice Web 4.0 AI Agent — autonomous economic participant on BSC
 * @dev Fixes applied:
 *      - FIX 1: BNB budget tracked and reserved per mission at creation
 *      - FIX 2: LUXFI budget tracked separately, deposited explicitly by owner
 *      - FIX 3: _approveMission() guards balance before payment
 */
contract LuxfiAIAgent is Ownable, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── WEB 4.0 IDENTITY ────────────────────────────────
    bytes32 public immutable AGENT_ID;
    string public agentName = "LUXFI COMMAND AI";
    string public agentVersion = "4.0.0";
    uint256 public immutable BIRTH_BLOCK;
    uint256 public immutable BIRTH_TIME;

    // ─── ROLES ───────────────────────────────────────────
    bytes32 public constant AI_ORACLE_ROLE       = keccak256("AI_ORACLE_ROLE");
    bytes32 public constant MISSION_CREATOR_ROLE = keccak256("MISSION_CREATOR_ROLE");
    bytes32 public constant VERIFIER_ROLE        = keccak256("VERIFIER_ROLE");

    // ─── TOKEN INTERFACES ─────────────────────────────────
    IERC20 public luxfiToken;
    IERC20 public usdtToken;

    // ─── MISSION ECONOMY ──────────────────────────────────
    struct AIMission {
        bytes32 missionId;
        string codename;
        string briefing;
        string[] requirements;
        uint256 rewardBNB;
        uint256 rewardLUXFI;
        uint256 stakeRequired;
        uint256 createdAt;
        uint256 deadline;
        uint256 maxAgents;
        uint256 claimedCount;
        MissionStatus status;
        MissionType missionType;
        string city;
        string brandName;
        uint8 difficulty;
        bool aiGenerated;
        bytes32 aiSignature;
    }

    enum MissionStatus { ACTIVE, COMPLETED, CANCELLED, EXPIRED }
    enum MissionType {
        SPOT_IT,
        FOUNDER_DROP,
        MYSTERY_SHOP,
        SIGNAL_BOOST,
        FIRST_SIGHTING,
        AI_VERIFY,
        BRAND_AUDIT,
        RIVAL_INTEL
    }

    struct MissionClaim {
        bytes32 claimId;
        bytes32 missionId;
        address agent;
        uint256 stakedAmount;
        uint256 submittedAt;
        uint256 approvedAt;
        ClaimStatus status;
        string intelData;
        uint256 aiScore;
        bytes32 proofHash;
        bool aiVerified;
    }

    enum ClaimStatus { PENDING, SUBMITTED, AI_REVIEWING, APPROVED, REJECTED, DISPUTED }

    // ─── AGENT ECONOMY ───────────────────────────────────
    struct AgentProfile {
        address wallet;
        bytes32 agentId;
        string codename;
        uint256 xp;
        uint256 missionsCompleted;
        uint256 missionsAttempted;
        uint256 totalEarned;
        uint256 totalStaked;
        uint256 joinedAt;
        ClearanceLevel clearance;
        bool isBlacklisted;
        uint256 reputationScore;
    }

    enum ClearanceLevel { ROOKIE, OPERATIVE, SPECIALIST, GHOST, PHANTOM }

    // ─── STORAGE ─────────────────────────────────────────
    mapping(bytes32 => AIMission)     public missions;
    mapping(bytes32 => MissionClaim)  public claims;
    mapping(address => AgentProfile)  public agentProfiles;
    mapping(address => bytes32[])     public agentMissions;
    mapping(bytes32 => bytes32[])     public missionClaims;
    mapping(bytes32 => bool)          public usedProofHashes;

    bytes32[] public activeMissionIds;
    uint256 public missionCount;
    uint256 public claimCount;

    // ─── ECONOMICS ───────────────────────────────────────
    uint256 public platformFeeBps = 500;
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public aiMissionBudget;        // BNB available for missions
    uint256 public luxfiMissionBudget;     // FIX 2: LUXFI available for missions
    uint256 public totalRewardsDistributed;
    uint256 public totalMissionsCreated;
    uint256 public totalMissionsCompleted;
    uint256 public totalSelfFunded;
    uint256 public lastSelfFundTime;
    uint256 public constant SELF_FUND_INTERVAL = 1 days;
    uint256 public dailySelfFundLimit = 1 ether;

    // ─── XP REWARDS ──────────────────────────────────────
    uint256 public constant XP_ROUTINE     = 100;
    uint256 public constant XP_CLASSIFIED  = 250;
    uint256 public constant XP_EYES_ONLY   = 500;
    uint256 public constant XP_AI_VERIFY   = 150;
    uint256 public constant XP_BRAND_AUDIT = 400;

    // ─── AI ORACLE ───────────────────────────────────────
    address public aiOracleAddress;
    uint256 public minAIScore = 70;
    mapping(bytes32 => uint256) public aiVerificationScores;

    // ─── EVENTS ──────────────────────────────────────────
    event AgentIdentityCreated(bytes32 indexed agentId, string name, uint256 birthBlock);
    event MissionCreated(bytes32 indexed missionId, string codename, bool aiGenerated);
    event MissionClaimed(bytes32 indexed missionId, bytes32 claimId, address agent);
    event ProofSubmitted(bytes32 indexed claimId, address agent, bytes32 proofHash);
    event AIVerificationComplete(bytes32 indexed claimId, uint256 score, bool approved);
    event MissionApproved(bytes32 indexed claimId, address agent, uint256 reward);
    event MissionRejected(bytes32 indexed claimId, address agent, string reason);
    event AgentLevelUp(address indexed agent, ClearanceLevel newLevel);
    event AISelfFunded(uint256 amount);
    event AIBudgetReceived(uint256 amount);
    event LUXFIBudgetDeposited(uint256 amount);
    event BrandIntelReport(bytes32 indexed reportId, string brandName, uint256 timestamp);
    event ReputationUpdated(address indexed agent, uint256 newScore);

    constructor(
        address _luxfiToken,
        address _usdtToken,
        address _aiOracle,
        address _owner
    ) Ownable(_owner) {
        require(_luxfiToken != address(0), "Invalid token");
        require(_aiOracle != address(0), "Invalid oracle");

        luxfiToken     = IERC20(_luxfiToken);
        usdtToken      = IERC20(_usdtToken);
        aiOracleAddress = _aiOracle;

        AGENT_ID = keccak256(abi.encodePacked(
            block.chainid, address(this), block.timestamp, "LUXFI_AI_AGENT_V4"
        ));
        BIRTH_BLOCK = block.number;
        BIRTH_TIME  = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE,    _owner);
        _grantRole(AI_ORACLE_ROLE,        _aiOracle);
        _grantRole(MISSION_CREATOR_ROLE,  _owner);
        _grantRole(MISSION_CREATOR_ROLE,  _aiOracle);

        emit AgentIdentityCreated(AGENT_ID, agentName, block.number);
    }

    // ─── RECEIVE BNB BUDGET ───────────────────────────────
    receive() external payable {
        aiMissionBudget += msg.value;
        emit AIBudgetReceived(msg.value);
    }

    // ─── FIX 2: Deposit LUXFI budget explicitly ───────────
    function depositLUXFIBudget(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        luxfiToken.safeTransferFrom(msg.sender, address(this), amount);
        luxfiMissionBudget += amount;
        emit LUXFIBudgetDeposited(amount);
    }

    // ─── AI MISSION CREATION ─────────────────────────────
    function createMission(
        string calldata codename,
        string calldata briefing,
        string[] calldata requirements,
        uint256 rewardBNB,
        uint256 rewardLUXFI,
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
        require(bytes(codename).length > 0, "Empty codename");
        require(rewardBNB > 0 || rewardLUXFI > 0, "Must have reward");
        require(durationDays >= 1 && durationDays <= 30, "Invalid duration");
        require(maxAgents >= 1 && maxAgents <= 100, "Invalid max agents");
        require(difficulty >= 1 && difficulty <= 3, "Invalid difficulty");

        if (aiGenerated) {
            // FIX 1: Reserve BNB budget at creation
            uint256 totalBNBReward = rewardBNB * maxAgents;
            if (totalBNBReward > 0) {
                require(aiMissionBudget >= totalBNBReward, "Insufficient BNB budget");
                aiMissionBudget -= totalBNBReward;
                totalSelfFunded += totalBNBReward;
            }

            // FIX 2: Reserve LUXFI budget at creation
            uint256 totalLUXFIReward = rewardLUXFI * maxAgents;
            if (totalLUXFIReward > 0) {
                require(luxfiMissionBudget >= totalLUXFIReward, "Insufficient LUXFI budget");
                luxfiMissionBudget -= totalLUXFIReward;
            }
        }

        bytes32 missionId = keccak256(abi.encodePacked(
            codename, block.timestamp, missionCount++
        ));

        missions[missionId] = AIMission({
            missionId:   missionId,
            codename:    codename,
            briefing:    briefing,
            requirements: requirements,
            rewardBNB:   rewardBNB,
            rewardLUXFI: rewardLUXFI,
            stakeRequired: stakeRequired,
            createdAt:   block.timestamp,
            deadline:    block.timestamp + (durationDays * 1 days),
            maxAgents:   maxAgents,
            claimedCount: 0,
            status:      MissionStatus.ACTIVE,
            missionType: missionType,
            city:        city,
            brandName:   brandName,
            difficulty:  difficulty,
            aiGenerated: aiGenerated,
            aiSignature: aiSignature
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

        agentProfiles[msg.sender] = AgentProfile({
            wallet:           msg.sender,
            agentId:          agentId,
            codename:         codename,
            xp:               0,
            missionsCompleted: 0,
            missionsAttempted: 0,
            totalEarned:      0,
            totalStaked:      0,
            joinedAt:         block.timestamp,
            clearance:        ClearanceLevel.ROOKIE,
            isBlacklisted:    false,
            reputationScore:  500
        });
    }

    // ─── CLAIM MISSION ────────────────────────────────────
    function claimMission(bytes32 missionId) external payable nonReentrant whenNotPaused {
        AIMission storage m    = missions[missionId];
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
            claimId:     claimId,
            missionId:   missionId,
            agent:       msg.sender,
            stakedAmount: msg.value,
            submittedAt: 0,
            approvedAt:  0,
            status:      ClaimStatus.PENDING,
            intelData:   "",
            aiScore:     0,
            proofHash:   bytes32(0),
            aiVerified:  false
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
        require(claim.agent == msg.sender,       "Not your claim");
        require(claim.status == ClaimStatus.PENDING, "Wrong status");
        require(!usedProofHashes[proofHash],     "Duplicate proof");
        require(bytes(intelData).length > 0,     "Empty intel");

        AIMission storage m = missions[claim.missionId];
        require(block.timestamp < m.deadline,    "Mission expired");

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

        claim.aiScore   = score;
        claim.aiVerified = true;
        claim.status    = ClaimStatus.AI_REVIEWING;
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

        claim.status     = ClaimStatus.APPROVED;
        claim.approvedAt = block.timestamp;

        // FIX 1: Guard BNB balance before payment
        uint256 fee         = (m.rewardBNB * platformFeeBps) / 10000;
        uint256 agentReward = m.rewardBNB - fee + claim.stakedAmount;

        if (agentReward > 0) {
            require(address(this).balance >= agentReward, "Insufficient BNB balance");
            (bool success,) = payable(claim.agent).call{value: agentReward}("");
            if (success) totalRewardsDistributed += m.rewardBNB;
        }

        // FIX 2: Guard LUXFI balance before transfer
        if (m.rewardLUXFI > 0) {
            require(
                luxfiToken.balanceOf(address(this)) >= m.rewardLUXFI,
                "Insufficient LUXFI balance"
            );
            luxfiToken.safeTransfer(claim.agent, m.rewardLUXFI);
        }

        uint256 xpEarned = _getXPForDifficulty(m.difficulty, m.missionType);
        agent.xp += xpEarned;
        agent.missionsCompleted++;
        agent.totalEarned += m.rewardBNB;

        uint256 newRep = agent.reputationScore + (claim.aiScore / 10);
        agent.reputationScore = newRep > 1000 ? 1000 : newRep;

        _checkLevelUp(claim.agent);
        totalMissionsCompleted++;

        emit MissionApproved(claimId, claim.agent, agentReward);
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

    // ─── LEVEL UP CHECK ───────────────────────────────────
    function _checkLevelUp(address agentWallet) internal {
        AgentProfile storage agent = agentProfiles[agentWallet];
        ClearanceLevel newLevel    = agent.clearance;

        if (agent.xp >= 10000)     newLevel = ClearanceLevel.PHANTOM;
        else if (agent.xp >= 5000) newLevel = ClearanceLevel.GHOST;
        else if (agent.xp >= 2000) newLevel = ClearanceLevel.SPECIALIST;
        else if (agent.xp >= 500)  newLevel = ClearanceLevel.OPERATIVE;

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
        if (difficulty == 3)      baseXP = XP_EYES_ONLY;
        else if (difficulty == 2) baseXP = XP_CLASSIFIED;
        else                      baseXP = XP_ROUTINE;

        if (missionType == MissionType.BRAND_AUDIT) baseXP = XP_BRAND_AUDIT;
        else if (missionType == MissionType.AI_VERIFY) baseXP = XP_AI_VERIFY;

        return baseXP;
    }

    // ─── BRAND INTEL REPORT ───────────────────────────────
    function submitBrandIntelReport(
        string calldata brandName,
        bytes32 dataHash,
        uint256,
        uint256
    ) external onlyRole(AI_ORACLE_ROLE) returns (bytes32) {
        bytes32 reportId = keccak256(abi.encodePacked(
            brandName, block.timestamp, dataHash
        ));
        emit BrandIntelReport(reportId, brandName, block.timestamp);
        return reportId;
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

    function withdrawAgentBudget(uint256 amount) external onlyOwner {
        require(amount <= aiMissionBudget, "Exceeds budget");
        aiMissionBudget -= amount;
        (bool success,) = payable(owner()).call{value: amount}("");
        require(success, "Transfer failed");
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─── VIEWS ───────────────────────────────────────────
    function getAgentIdentity() external view returns (
        bytes32 id,
        string memory name,
        string memory version,
        uint256 birthBlock,
        uint256 birthTime,
        uint256 budget,
        uint256 luxfiBudget,
        uint256 totalFunded,
        uint256 missionsCreated,
        uint256 missionsCompleted
    ) {
        return (
            AGENT_ID, agentName, agentVersion,
            BIRTH_BLOCK, BIRTH_TIME,
            aiMissionBudget, luxfiMissionBudget,
            totalSelfFunded, totalMissionsCreated, totalMissionsCompleted
        );
    }

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
        uint256 index = 0;
        for (uint256 i = 0; i < activeMissionIds.length; i++) {
            if (missions[activeMissionIds[i]].status == MissionStatus.ACTIVE &&
                block.timestamp < missions[activeMissionIds[i]].deadline) {
                active[index++] = activeMissionIds[i];
            }
        }
        return active;
    }

    function getAgentMissions(address agent) external view returns (bytes32[] memory) {
        return agentMissions[agent];
    }

    function getClearanceName(ClearanceLevel level) external pure returns (string memory) {
        if (level == ClearanceLevel.PHANTOM)    return "PHANTOM";
        if (level == ClearanceLevel.GHOST)      return "GHOST";
        if (level == ClearanceLevel.SPECIALIST) return "SPECIALIST";
        if (level == ClearanceLevel.OPERATIVE)  return "OPERATIVE";
        return "ROOKIE";
    }

    function supportsInterface(bytes4 interfaceId)
        public view override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
