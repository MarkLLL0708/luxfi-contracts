const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "BNB");

  const addresses = {};

  // ─── 1. LuxfiToken ────────────────────────────────────
  console.log("\n[1/14] Deploying LuxfiToken...");
  const LuxfiToken = await ethers.getContractFactory("LuxfiToken");
  const luxfiToken = await LuxfiToken.deploy(
    "0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE",
    "0x10ED43C718714eb63d5aA57B78B54704E256024E",
    ethers.ZeroAddress
  );
  await luxfiToken.waitForDeployment();
  addresses.LuxfiToken = await luxfiToken.getAddress();
  console.log("LuxfiToken:", addresses.LuxfiToken);

  // ─── 2. LuxfiFeeDistributor ───────────────────────────
  console.log("\n[2/14] Deploying LuxfiFeeDistributor...");
  const FeeDistributor = await ethers.getContractFactory("LuxfiFeeDistributor");
  const feeDistributor = await FeeDistributor.deploy(
    addresses.LuxfiToken,
    "0x55d398326f99059fF775485246999027B3197955",
    "0x10ED43C718714eb63d5aA57B78B54704E256024E",
    deployer.address,
    deployer.address,
    deployer.address,
    deployer.address
  );
  await feeDistributor.waitForDeployment();
  addresses.LuxfiFeeDistributor = await feeDistributor.getAddress();
  console.log("LuxfiFeeDistributor:", addresses.LuxfiFeeDistributor);

  // ─── 3. Wire FeeDistributor into LuxfiToken ───────────
  console.log("\n[3/14] Wiring FeeDistributor into LuxfiToken...");
  await luxfiToken.setFeeDistributor(addresses.LuxfiFeeDistributor);
  console.log("Done");

  // ─── 4. EcoGovernor ───────────────────────────────────
  console.log("\n[4/14] Deploying EcoGovernor...");
  const EcoGovernor = await ethers.getContractFactory("EcoGovernor");
  const ecoGovernor = await EcoGovernor.deploy(addresses.LuxfiToken);
  await ecoGovernor.waitForDeployment();
  addresses.EcoGovernor = await ecoGovernor.getAddress();
  console.log("EcoGovernor:", addresses.EcoGovernor);

  // ─── 5. BrandGovernor ─────────────────────────────────
  console.log("\n[5/14] Deploying BrandGovernor...");
  const BrandGovernor = await ethers.getContractFactory("BrandGovernor");
  const brandGovernor = await BrandGovernor.deploy(addresses.LuxfiToken);
  await brandGovernor.waitForDeployment();
  addresses.BrandGovernor = await brandGovernor.getAddress();
  console.log("BrandGovernor:", addresses.BrandGovernor);

  // ─── 6. Set Governance ────────────────────────────────
  console.log("\n[6/14] Setting Governance on LuxfiToken...");
  await luxfiToken.setGovernance(addresses.EcoGovernor, addresses.BrandGovernor);
  console.log("Done");

  // ─── 7. ParticipationVault ────────────────────────────
  console.log("\n[7/14] Deploying ParticipationVault...");
  const ParticipationVault = await ethers.getContractFactory("ParticipationVault");
  const participationVault = await ParticipationVault.deploy(addresses.LuxfiToken);
  await participationVault.waitForDeployment();
  addresses.ParticipationVault = await participationVault.getAddress();
  console.log("ParticipationVault:", addresses.ParticipationVault);

  // ─── 8. RewardDistributor ─────────────────────────────
  console.log("\n[8/14] Deploying RewardDistributor...");
  const RewardDistributor = await ethers.getContractFactory("RewardDistributor");
  const rewardDistributor = await RewardDistributor.deploy(addresses.LuxfiToken);
  await rewardDistributor.waitForDeployment();
  addresses.RewardDistributor = await rewardDistributor.getAddress();
  console.log("RewardDistributor:", addresses.RewardDistributor);

  // ─── 9. BrandRegistry ─────────────────────────────────
  console.log("\n[9/14] Deploying BrandRegistry...");
  const BrandRegistry = await ethers.getContractFactory("BrandRegistry");
  const brandRegistry = await BrandRegistry.deploy();
  await brandRegistry.waitForDeployment();
  addresses.BrandRegistry = await brandRegistry.getAddress();
  console.log("BrandRegistry:", addresses.BrandRegistry);

  // ─── 10. TransparencyOracle ───────────────────────────
  console.log("\n[10/14] Deploying TransparencyOracle...");
  const TransparencyOracle = await ethers.getContractFactory("TransparencyOracle");
  const transparencyOracle = await TransparencyOracle.deploy();
  await transparencyOracle.waitForDeployment();
  addresses.TransparencyOracle = await transparencyOracle.getAddress();
  console.log("TransparencyOracle:", addresses.TransparencyOracle);

  // ─── 11. RWBOMarketplace ──────────────────────────────
  console.log("\n[11/14] Deploying RWBOMarketplace...");
  const RWBOMarketplace = await ethers.getContractFactory("RWBOMarketplace");
  const rwboMarketplace = await RWBOMarketplace.deploy(addresses.LuxfiToken);
  await rwboMarketplace.waitForDeployment();
  addresses.RWBOMarketplace = await rwboMarketplace.getAddress();
  console.log("RWBOMarketplace:", addresses.RWBOMarketplace);

  // ─── 12. LuxfiAIAgent ─────────────────────────────────
  console.log("\n[12/14] Deploying LuxfiAIAgent...");
  const LuxfiAIAgent = await ethers.getContractFactory("LuxfiAIAgent");
  const aiAgent = await LuxfiAIAgent.deploy(
    addresses.LuxfiToken,
    "0x55d398326f99059fF775485246999027B3197955",
    deployer.address,
    deployer.address
  );
  await aiAgent.waitForDeployment();
  addresses.LuxfiAIAgent = await aiAgent.getAddress();
  console.log("LuxfiAIAgent:", addresses.LuxfiAIAgent);

  // ─── 13. LuxfiStaking ─────────────────────────────────
  console.log("\n[13/14] Deploying LuxfiStaking...");
  const LuxfiStaking = await ethers.getContractFactory("LuxfiStaking");
  const luxfiStaking = await LuxfiStaking.deploy(
    addresses.LuxfiToken,
    addresses.LuxfiFeeDistributor
  );
  await luxfiStaking.waitForDeployment();
  addresses.LuxfiStaking = await luxfiStaking.getAddress();
  console.log("LuxfiStaking:", addresses.LuxfiStaking);

  // ─── 14. LuxfiCircuitBreaker ──────────────────────────
  console.log("\n[14/14] Deploying LuxfiCircuitBreaker...");
  const LuxfiCircuitBreaker = await ethers.getContractFactory("LuxfiCircuitBreaker");
  const circuitBreaker = await LuxfiCircuitBreaker.deploy();
  await circuitBreaker.waitForDeployment();
  addresses.LuxfiCircuitBreaker = await circuitBreaker.getAddress();
  console.log("LuxfiCircuitBreaker:", addresses.LuxfiCircuitBreaker);

  // ─── POST DEPLOY WIRING ───────────────────────────────
  console.log("\n======= POST DEPLOY WIRING =======");

  const MINTER_ROLE   = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"));
  const OPERATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("OPERATOR_ROLE"));

  console.log("Granting MINTER_ROLE to LuxfiAIAgent...");
  await luxfiToken.grantRole(MINTER_ROLE, addresses.LuxfiAIAgent);

  console.log("Granting OPERATOR_ROLE to ParticipationVault...");
  await luxfiToken.grantRole(OPERATOR_ROLE, addresses.ParticipationVault);

  console.log("Whitelisting LuxfiToken in FeeDistributor...");
  await feeDistributor.setWhitelistedSender(addresses.LuxfiToken, true);

  console.log("Whitelisting LuxfiAIAgent in FeeDistributor...");
  await feeDistributor.setWhitelistedSender(addresses.LuxfiAIAgent, true);

  console.log("Whitelisting LuxfiStaking in FeeDistributor...");
  await feeDistributor.setWhitelistedSender(addresses.LuxfiStaking, true);

  console.log("Setting StakingPool in FeeDistributor...");
  await feeDistributor.updateAddresses(
    deployer.address,
    addresses.LuxfiAIAgent,
    deployer.address,
    addresses.LuxfiStaking
  );

  // ─── FINAL SUMMARY ────────────────────────────────────
  console.log("\n========================================");
  console.log("DEPLOYMENT COMPLETE — SAVE THESE ADDRESSES");
  console.log("========================================");
  Object.entries(addresses).forEach(([name, addr]) => {
    console.log(`${name.padEnd(25)}: ${addr}`);
  });
  console.log("========================================");
  console.log("\nNEXT STEPS:");
  console.log("1. Update backend .env with contract addresses");
  console.log("2. Update Lovable frontend with contract addresses");
  console.log("3. Transfer ownership to Gnosis Safe");
  console.log("4. Verify contracts on BSCScan");
  console.log("5. Fund LuxfiAIAgent with BNB for mission rewards");
  console.log("6. Call luxfiToken.setTransfersEnabled(true) when ready");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
