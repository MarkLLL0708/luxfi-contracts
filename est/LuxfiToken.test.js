const { expect } = require("chai");
const { ethers } = require("hardhat");
describe("LuxfiToken", function () {
let token, owner, buyer1, buyer2;
beforeEach(async function () {
[owner, buyer1, buyer2] = await ethers.getSigners();
const LuxfiToken = await ethers.getContractFactory("LuxfiToken");
token = await LuxfiToken.deploy();
await token.waitForDeployment();
});
it("Should deploy with correct name and symbol", async function () {
expect(await token.name()).to.equal("LUXFI");
expect(await token.symbol()).to.equal("LUXFI");
});
it("Should register an asset", async function () {
await token.registerAsset("CLAY_AND_CLOUD", "Beverages", 50000000, 200000000, 10);
const asset = await token.getAsset(0);
expect(asset.name).to.equal("CLAY_AND_CLOUD");
expect(asset.active).to.equal(true);
expect(asset.totalTokens).to.equal(200000000);
});
it("Should only allow owner to register asset", async function () {
await expect(
token.connect(buyer1).registerAsset("TEST", "Test", 1000, 1000, 10)
).to.be.revertedWithCustomError(token, "OwnableUnauthorizedAccount");
});
it("Should buy tokens correctly", async function () {
await token.registerAsset("CLAY_AND_CLOUD", "Beverages", 50000000, 200000000, 10);
const cost = await token.getCostBNB(0, 100);
await token.connect(buyer1).buyTokens(0, 100, { value: cost });
expect(await token.getHolding(buyer1.address, 0)).to.equal(100);
});
it("Should refund excess BNB", async function () {
await token.registerAsset("CLAY_AND_CLOUD", "Beverages", 50000000, 200000000, 10);
const cost = await token.getCostBNB(0, 100);
const excess = ethers.parseEther("1");
const before = await ethers.provider.getBalance(buyer1.address);
const tx = await token.connect(buyer1).buyTokens(0, 100, { value: cost + excess });
const receipt = await tx.wait();
const gasUsed = receipt.gasUsed * receipt.gasPrice;
const after = await ethers.provider.getBalance(buyer1.address);
expect(before - after - gasUsed).to.be.closeTo(cost, ethers.parseEther("0.001"));
});
it("Should not buy more than MAX_PURCHASE", async function () {
await token.registerAsset("CLAY_AND_CLOUD", "Beverages", 50000000, 200000000, 10);
const amount = 1000001;
const cost = await token.getCostBNB(0, amount);
await expect(
token.connect(buyer1).buyTokens(0, amount, { value: cost })
).to.be.revertedWith("Exceeds max purchase");
});
it("Should not buy from inactive asset", async function () {
await token.registerAsset("CLAY_AND_CLOUD", "Beverages", 50000000, 200000000, 10);
await token.setAssetActive(0, false);
const cost = await token.getCostBNB(0, 100);
await expect(
token.connect(buyer1).buyTokens(0, 100, { value: cost })
).to.be.revertedWith("Asset not active");
});
it("Should pause and unpause", async function () {
await token.registerAsset("CLAY_AND_CLOUD", "Beverages", 50000000, 200000000, 10);
await token.pause();
const cost = await token.getCostBNB(0, 100);
await expect(
token.connect(buyer1).buyTokens(0, 100, { value: cost })
).to.be.revertedWithCustomError(token, "EnforcedPause");
await token.unpause();
await token.connect(buyer1).buyTokens(0, 100, { value: cost });
expect(await token.getHolding(buyer1.address, 0)).to.equal(100);
});
it("Should distribute yield correctly", async function () {
await token.registerAsset("CLAY_AND_CLOUD", "Beverages", 50000000, 200000000, 10);
await token.distributeYield(0, [buyer1.address, buyer2.address], [500, 300]);
expect(await token.getYield(buyer1.address, 0)).to.equal(500);
expect(await token.getYield(buyer2.address, 0)).to.equal(300);
});
it("Should withdraw BNB to owner", async function () {
await token.registerAsset("CLAY_AND_CLOUD", "Beverages", 50000000, 200000000, 10);
const cost = await token.getCostBNB(0, 100);
await token.connect(buyer1).buyTokens(0, 100, { value: cost });
const before = await ethers.provider.getBalance(owner.address);
await token.withdraw();
const after = await ethers.provider.getBalance(owner.address);
expect(after).to.be.gt(before);
});
it("Should get all assets", async function () {
await token.registerAsset("CLAY_AND_CLOUD", "Beverages", 50000000, 200000000, 10);
await token.registerAsset("ROGUE_BREWERY", "Beer", 80000000, 200000000, 15);
const assets = await token.getAllAssets();
expect(assets.length).to.equal(2);
expect(assets[0].name).to.equal("CLAY_AND_CLOUD");
expect(assets[1].name).to.equal("ROGUE_BREWERY");
});
});
