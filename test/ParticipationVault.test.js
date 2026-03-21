const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ParticipationVault", function () {
  let token, vault, owner, user1, user2;

  beforeEach(async function () {
    [owner, user1, user2] = await ethers.getSigners();

    // Deploy a simple mock ERC20 token
    const MockToken = await ethers.getContractFactory("MockERC20");
    token = await MockToken.deploy("LUXFI Token", "LUXFI");
    await token.waitForDeployment();

    // Deploy ParticipationVault with token + zero address for feeDistributor
    const ParticipationVault = await ethers.getContractFactory("ParticipationVault");
    vault = await ParticipationVault.deploy(
      await token.getAddress(),
      ethers.ZeroAddress
    );
    await vault.waitForDeployment();

    // Mint tokens to user1
    await token.mint(user1.address, ethers.parseEther("10000"));
    await token.connect(user1).approve(await vault.getAddress(), ethers.parseEther("10000"));

    // Add brand 0
    await vault.connect(owner).addBrand(0);
  });

  it("Should stake tokens", async function () {
    await vault.connect(user1).stake(0, ethers.parseEther("100"), 1);
    const p = await vault.getParticipation(user1.address, 0);
    expect(p.active).to.equal(true);
  });

  it("Should not stake zero amount", async function () {
    await expect(
      vault.connect(user1).stake(0, 0, 1)
    ).to.be.revertedWith("Zero amount");
  });

  it("Should not stake with invalid lock period", async function () {
    await expect(
      vault.connect(user1).stake(0, ethers.parseEther("100"), 0)
    ).to.be.revertedWith("Invalid lock period");
  });

  it("Should not unstake before lock period", async function () {
    await vault.connect(user1).stake(0, ethers.parseEther("100"), 30);
    // Stake fee is 0.5% so tokenAmount = 99.5 ether; unstake 90 to pass amount check but hit lock period
    await expect(
      vault.connect(user1).unstake(0, ethers.parseEther("90"))
    ).to.be.revertedWith("Still in lock period");
  });

  it("Should get brand pool info", async function () {
    const pool = await vault.getBrandPool(0);
    expect(pool.active).to.equal(true);
    expect(pool.slashFactorBps).to.equal(10000);
  });

  it("Should get user brands", async function () {
    await vault.connect(user1).stake(0, ethers.parseEther("100"), 1);
    const brands = await vault.getUserBrands(user1.address);
    expect(brands.length).to.equal(1);
    expect(brands[0]).to.equal(0);
  });
});
