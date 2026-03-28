const { run } = require("hardhat");

const addresses = {
  LuxfiToken: "",
  LuxfiFeeDistributor: "",
  EcoGovernor: "",
  BrandGovernor: "",
  ParticipationVault: "",
  RewardDistributor: "",
  BrandRegistry: "",
  TransparencyOracle: "",
  RWBOMarketplace: "",
  LuxfiAIAgent: "",
  LuxfiStaking: "",
};

async function main() {
  console.log("Verifying contracts on BSCScan...");

  await run("verify:verify", {
    address: addresses.LuxfiToken,
    constructorArguments: [
      "0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE",
      "0x10ED43C718714eb63d5aA57B78B54704E256024E",
      addresses.LuxfiFeeDistributor
    ]
  });

  await run("verify:verify", {
    address: addresses.EcoGovernor,
    constructorArguments: [addresses.LuxfiToken]
  });

  await run("verify:verify", {
    address: addresses.BrandGovernor,
    constructorArguments: [addresses.LuxfiToken]
  });

  await run("verify:verify", {
    address: addresses.ParticipationVault,
    constructorArguments: [addresses.LuxfiToken, addresses.LuxfiFeeDistributor]
  });

  await run("verify:verify", {
    address: addresses.RewardDistributor,
    constructorArguments: [addresses.LuxfiToken]
  });

  await run("verify:verify", {
    address: addresses.BrandRegistry,
    constructorArguments: []
  });

  await run("verify:verify", {
    address: addresses.TransparencyOracle,
    constructorArguments: []
  });

  await run("verify:verify", {
    address: addresses.RWBOMarketplace,
    constructorArguments: [addresses.LuxfiToken, addresses.LuxfiFeeDistributor]
  });

  await run("verify:verify", {
    address: addresses.LuxfiStaking,
    constructorArguments: [addresses.LuxfiToken, addresses.LuxfiFeeDistributor]
  });

  console.log("All contracts verified on BSCScan");
}

main().catch(console.error);
