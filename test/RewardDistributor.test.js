const { expect } = require("chai");
const { ethers } = require("hardhat");
describe("RewardDistributor", function () {
let token, distributor, owner, user1, user2;
beforeEach(async function () {
[owner, user1, user2] = await ethers.getSigners();
const LuxfiToken = await ethers.getContractFactory("LuxfiToken");
token = await LuxfiToken.deploy();
await token.waitForDeployment();
const RewardDistributor = await ethers.getContractFactory("RewardDistributor");
distributor = await RewardDistributor.deploy(await token.getAddress());
await distributor.waitForDeployment();
await token.registerAsset("CLAY_AND_CLOUD", "Beverages", 50000000, 200000000, 10);
const cost = await token.getCostBNB(0, 100000);
await token.connect(owner).buyTokens(0, 100000, { value: cost });
await token.approve(await distributor.getAddress(), ethers.parseEther("100000"));
});
it("Should create a reward pool", async function () {
await distributor.createPool(0, ethers.parseEther("1000"), 30);
const pool = await distributor.getPool(0);
expect(pool.totalReward).to.equal(ethers.parseEther("1000"));
expect(pool.active).to.equal(true);
});
it("Should allocate rewards to users", async function () {
await distributor.createPool(0, ethers.parseEther("1000"), 30);
await distributor.allocateRewards(0, [user1.address, user2.address], [ethers.parseEther("600"), ethers.parseEther("400")]);
expect(await distributor.getClaimable(0, user1.address)).to.equal(ethers.parseEther("600"));
expect(await distributor.getClaimable(0, user2.address)).to.equal(ethers.parseEther("400"));
});
it("Should allow user to claim reward", async function () {
await distributor.createPool(0, ethers.parseEther("1000"), 30);
await distributor.allocateRewards(0, [user1.address], [ethers.parseEther("600")]);
const before = await token.balanceOf(user1.address);
await distributor.connect(user1).claimReward(0);
const after = await token.balanceOf(user1.address);
expect(after - before).to.equal(ethers.parseEther("600"));
});
it("Should not allow double claim", async function () {
await distributor.createPool(0, ethers.parseEther("1000"), 30);
await distributor.allocateRewards(0, [user1.address], [ethers.parseEther("600")]);
await distributor.connect(user1).claimReward(0);
await expect(
distributor.connect(user1).claimReward(0)
).to.be.revertedWith("Already claimed");
});
it("Should not claim with nothing allocated", async function () {
await distributor.createPool(0, ethers.parseEther("1000"), 30);
await expect(
distributor.connect(user1).claimReward(0)
).to.be.revertedWith("Nothing to claim");
});
it("Should track claimed status", async function () {
await distributor.createPool(0, ethers.parseEther("1000"), 30);
await distributor.allocateRewards(0, [user1.address], [ethers.parseEther("600")]);
expect(await distributor.hasClaimed(0, user1.address)).to.equal(false);
await distributor.connect(user1).claimReward(0);
expect(await distributor.hasClaimed(0, user1.address)).to.equal(true);
});
});
