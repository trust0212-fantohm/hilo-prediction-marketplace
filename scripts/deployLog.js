const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");
require("dotenv").config();

// Log file path
const LOG_DIR = path.join(__dirname, "../logs");
const LOG_FILE = path.join(LOG_DIR, `deployment_${new Date().toISOString().replace(/:/g, "-")}.log`);

// Ensure logs directory exists
if (!fs.existsSync(LOG_DIR)) {
  fs.mkdirSync(LOG_DIR, { recursive: true });
}

// Connect to provider
const provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL || "http://localhost:8545");

// Load deployer's private key from the environment
const deployerPrivateKey = process.env.DEPLOYER_PRIVATE_KEY;
if (!deployerPrivateKey) {
  throw new Error("DEPLOYER_PRIVATE_KEY is not set in your .env file.");
}

// Create wallet
const deployer = new ethers.Wallet(deployerPrivateKey, provider);

async function main() {
  console.log("Starting deployment logging process...");
  console.log(`Logs will be saved to: ${LOG_FILE}`);
  
  // Initialize log file
  fs.writeFileSync(LOG_FILE, `# Hilo Deployment Log\nDate: ${new Date().toISOString()}\nDeployer: ${deployer.address}\n\n`);
  
  try {
    // Load deployment info from deployment.json
    const deploymentFile = path.join(__dirname, "../build/deployment.json");
    if (!fs.existsSync(deploymentFile)) {
      throw new Error("Deployment file not found. Please run deployment first.");
    }
    
    const deploymentConfig = JSON.parse(fs.readFileSync(deploymentFile, "utf8"));
    
    // Log deployment information
    const log = [
      "## Contract Addresses",
      ""
    ];
    
    // Add each contract address to the log
    for (const [name, address] of Object.entries(deploymentConfig.contracts)) {
      log.push(`- **${name}**: \`${address}\``);
      
      // Verify contract info if on a public network
      try {
        const code = await provider.getCode(address);
        const codeSize = (code.length - 2) / 2; // Remove '0x' and convert hex to bytes
        log.push(`  - Code size: ${codeSize} bytes`);
        log.push(`  - Verified: ${code !== "0x" ? "Yes" : "No"}`);
      } catch (error) {
        log.push(`  - Error checking code: ${error.message}`);
      }
      
      log.push("");
    }
    
    // Add network information
    const network = await provider.getNetwork();
    log.push("## Network Information");
    log.push(`- **Chain ID**: ${network.chainId}`);
    log.push(`- **Network Name**: ${network.name || "Custom/Private"}`);
    log.push("");
    
    // Add deployment configuration
    log.push("## Deployment Configuration");
    log.push("```json");
    log.push(JSON.stringify(deploymentConfig.config || {}, null, 2));
    log.push("```");
    
    // Write to log file
    fs.appendFileSync(LOG_FILE, log.join("\n"));
    
    console.log("Deployment logging completed successfully!");
    console.log(`Log file: ${LOG_FILE}`);
  } catch (error) {
    console.error("Error logging deployment:", error);
    fs.appendFileSync(LOG_FILE, `\n## ERROR\n${error.stack || error.message || error}`);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });