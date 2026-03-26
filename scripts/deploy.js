const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  console.log("Deploying with:", deployer.address);

  const Token = await hre.ethers.getContractFactory("LuxfiToken");
  const token = await Token.deploy();

  await token.waitForDeployment();

  console.log("✅ Token deployed to:", await token.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
