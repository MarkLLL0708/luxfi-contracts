const { expect } = require("chai");
const { ethers } = require("hardhat");
describe("BrandRegistry", function () {
let registry, owner, brand1, brand2;
beforeEach(async function () {
[owner, brand1, brand2] = await ethers.getSigners();
const BrandRegistry = await ethers.getContractFactory("BrandRegistry");
registry = await BrandRegistry.deploy();
await registry.waitForDeployment();
});
it("Should register a brand", async function () {
await registry.registerBrand("Clay and Cloud", "Beverages", "Vietnam", brand1.address);
const brand = await registry.getBrand(0);
expect(brand.name).to.equal("Clay and Cloud");
expect(brand.status).to.equal(0);
});
it("Should only allow owner to register", async function () {
await expect(
registry.connect(brand1).registerBrand("Test", "Test", "Test", brand2.address)
).to.be.revertedWithCustomError(registry, "OwnableUnauthorizedAccount");
});
it("Should activate a brand", async function () {
await registry.registerBrand("Clay and Cloud", "Beverages", "Vietnam", brand1.address);
await registry.activateBrand(0);
const brand = await registry.getBrand(0);
expect(brand.status).to.equal(1);
expect(await registry.isVerifiedBrand(brand1.address)).to.equal(true);
});
it("Should suspend a brand", async function () {
await registry.registerBrand("Clay and Cloud", "Beverages", "Vietnam", brand1.address);
await registry.activateBrand(0);
await registry.suspendBrand(0);
const brand = await registry.getBrand(0);
expect(brand.status).to.equal(2);
expect(await registry.isVerifiedBrand(brand1.address)).to.equal(false);
});
it("Should update revenue", async function () {
await registry.registerBrand("Clay and Cloud", "Beverages", "Vietnam", brand1.address);
await registry.updateRevenue(0, 50000);
const brand = await registry.getBrand(0);
expect(brand.monthlyRevenue).to.equal(50000);
});
it("Should not register same wallet twice", async function () {
await registry.registerBrand("Clay and Cloud", "Beverages", "Vietnam", brand1.address);
await registry.activateBrand(0);
await expect(
registry.registerBrand("Duplicate", "Beverages", "Vietnam", brand1.address)
).to.be.revertedWith("Already registered");
});
it("Should get all brands", async function () {
await registry.registerBrand("Clay and Cloud", "Beverages", "Vietnam", brand1.address);
await registry.registerBrand("Rogue Brewery", "Beer", "Vietnam", brand2.address);
const brands = await registry.getAllBrands();
expect(brands.length).to.equal(2);
});
it("Should set POS connected", async function () {
await registry.registerBrand("Clay and Cloud", "Beverages", "Vietnam", brand1.address);
await registry.setPOSConnected(0, true);
const brand = await registry.getBrand(0);
expect(brand.posConnected).to.equal(true);
});
});
