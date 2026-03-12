const { expect } = require("chai");
const { ethers } = require("hardhat");
describe("ParticipationVault", function () {
let token, vault, owner, user1, user2;
beforeEach(async function () {
[owner, user1, user2] = await ethers.getSigners();
const LuxfiToken = await ethers.getContractFactory("LuxfiToken");
token = await LuxfiToken.deploy();
await token.waitForDeployment();
const ParticipationVault = await ethers.getContractFactory("ParticipationVault");
vault = await ParticipationVault.deploy(await token.getAddress());
await vault.waitForDeployment();
await token.registerAsset("CLAY_AND_CLOUD", "Beverages", 50000000, 200000000, 10);
const cost = await token.getCostBNB(0, 10000);
await token.connect(user1).buyTokens(0, 10000, { value: cost });
await token.connect(user1).approve(await vault.getAddress(), ethers.parseEther("10000"));
});
it("Should stake tokens", async function () {
await vault.connect(user1).stake(0, ethers.parseEther("100"), 30 * 24 * 60 * 60);
expect(await vault.getBrandStake(user1.address, 0)).to.equal(ethers.parseEther("100"));
expect(await vault.getTotalBrandStake(0)).to.equal(ethers.parseEther("100"));
});
it("Should not stake below minimum", async function () {
await expect(
vault.connect(user1).stake(0, ethers.parseEther("50"), 30 * 24 * 60 * 60)
).to.be.revertedWith("Below minimum stake");
});
it("Should not stake with invalid lock period", async function () {
await expect(
vault.connect(user1).stake(0, ethers.parseEther("100"), 10)
).to.be.revertedWith("Invalid lock period");
});
it("Should calculate share percentage correctly", async function () {
await vault.connect(user1).stake(0, ethers.parseEther("100"), 30 * 24 * 60 * 60);
const share = await vault.getSharePercentage(user1.address, 0);
expect(share).to.equal(10000);
});
it("Should not unstake before lock period", async function () {
await vault.connect(user1).stake(0, ethers.parseEther("100"), 30 * 24 * 60 * 60);
await expect(
vault.connect(user1).unstake(0)
).to.be.revertedWith("Still locked");
});
it("Should return participations for user", async function () {
await vault.connect(user1).stake(0, ethers.parseEther("100"), 30 * 24 * 60 * 60);
const participations = await vault.getParticipations(user1.address);
expect(participations.length).to.equal(1);
expect(participations[0].active).to.equal(true);
});
});
