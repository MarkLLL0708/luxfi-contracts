// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
contract TransparencyOracle is Ownable, Pausable, ReentrancyGuard {
struct RevenueReport {
    uint256 brandId;
    uint256 periodStart;
    uint256 periodEnd;
    uint256 totalRevenue;
    bytes32 merkleRoot;
    uint256 submittedAt;
    bool verified;
}

uint256 public reportCount;
mapping(uint256 => RevenueReport) public reports;
mapping(uint256 => uint256[]) public brandReports;
mapping(address => bool) public authorizedReporters;

event ReporterAuthorized(address indexed reporter, bool status);
event ReportSubmitted(uint256 indexed reportId, uint256 indexed brandId, bytes32 merkleRoot);
event ReportVerified(uint256 indexed reportId);

constructor() Ownable(msg.sender) {}

function setReporter(address reporter, bool authorized) external onlyOwner {
    authorizedReporters[reporter] = authorized;
    emit ReporterAuthorized(reporter, authorized);
}

function submitReport(uint256 brandId, uint256 periodStart, uint256 periodEnd, uint256 totalRevenue, bytes32 merkleRoot) external whenNotPaused nonReentrant returns (uint256) {
    require(authorizedReporters[msg.sender] || msg.sender == owner(), "Not authorized");
    require(periodEnd > periodStart, "Invalid period");
    require(merkleRoot != bytes32(0), "Empty merkle root");
    uint256 id = reportCount++;
    reports[id] = RevenueReport(brandId, periodStart, periodEnd, totalRevenue, merkleRoot, block.timestamp, false);
    brandReports[brandId].push(id);
    emit ReportSubmitted(id, brandId, merkleRoot);
    return id;
}

function verifyReport(uint256 reportId) external onlyOwner {
    require(!reports[reportId].verified, "Already verified");
    reports[reportId].verified = true;
    emit ReportVerified(reportId);
}

function verifyLeaf(uint256 reportId, bytes32 leaf, bytes32[] calldata proof) external view returns (bool) {
    bytes32 root = reports[reportId].merkleRoot;
    bytes32 hash = leaf;
    for (uint256 i = 0; i < proof.length; i++) {
        if (hash < proof[i]) {
            hash = keccak256(abi.encodePacked(hash, proof[i]));
        } else {
            hash = keccak256(abi.encodePacked(proof[i], hash));
        }
    }
    return hash == root;
}

function getReport(uint256 id) external view returns (RevenueReport memory) {
    return reports[id];
}

function getBrandReports(uint256 brandId) external view returns (uint256[] memory) {
    return brandReports[brandId];
}

function getLatestReport(uint256 brandId) external view returns (RevenueReport memory) {
    uint256[] memory ids = brandReports[brandId];
    require(ids.length > 0, "No reports");
    return reports[ids[ids.length - 1]];
}

function pause() external onlyOwner { _pause(); }
function unpause() external onlyOwner { _unpause(); }
}
