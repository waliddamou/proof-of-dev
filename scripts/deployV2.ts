/**
 * Deploy ProofOfDevV2 to Sepolia — self-compiling, no manual artifact step.
 *
 * Unlike the old scripts/deploy.ts (which required you to run `solc` by hand and
 * assemble artifacts/ProofOfDev.json yourself), this script compiles the contract
 * in-process with the `solc` npm package and deploys with ethers v6. It is also
 * ESM-safe (this project uses "type": "module").
 *
 * Install the compiler once:
 *   npm install --save-dev solc
 *
 * Required env vars (read from the shell or .env.local):
 *   DEPLOYER_PRIVATE_KEY         — deployer wallet (needs Sepolia ETH)
 *   NEXT_PUBLIC_ALCHEMY_API_KEY  — Alchemy Sepolia RPC key
 *   MINT_SIGNER_ADDRESS          — trusted voucher signer (the server's signer address)
 * Optional:
 *   BASE_URI                     — token metadata base URI
 *
 * Run:
 *   node --import tsx scripts/deployV2.ts
 *   # or: npx tsx scripts/deployV2.ts
 *
 * After deploying, copy the printed address into .env.local:
 *   NEXT_PUBLIC_CONTRACT_ADDRESS_V2=0x...
 */

import { ethers } from "ethers";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

// dotenv is a project dependency; load .env.local if present.
import { config as loadEnv } from "dotenv";

const __dirname = dirname(fileURLToPath(import.meta.url));
loadEnv({ path: resolve(__dirname, "../.env.local") });

const require = createRequire(import.meta.url);

const CONTRACT_NAME = "ProofOfDevV2";
const CONTRACT_FILE = "ProofOfDevV2.sol";

function compile(): { abi: unknown[]; bytecode: string } {
  // solc is CommonJS; require() keeps it simple under ESM.
  const solc = require("solc");

  const sourcePath = resolve(__dirname, "../contracts", CONTRACT_FILE);
  const source = readFileSync(sourcePath, "utf8");

  const input = {
    language: "Solidity",
    sources: { [CONTRACT_FILE]: { content: source } },
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: "paris",
      outputSelection: {
        "*": { "*": ["abi", "evm.bytecode.object"] },
      },
    },
  };

  const output = JSON.parse(solc.compile(JSON.stringify(input)));

  if (output.errors) {
    const fatal = output.errors.filter((e: { severity: string }) => e.severity === "error");
    for (const e of output.errors) console.error(e.formattedMessage);
    if (fatal.length > 0) throw new Error("Solidity compilation failed");
  }

  const c = output.contracts[CONTRACT_FILE][CONTRACT_NAME];
  return { abi: c.abi, bytecode: "0x" + c.evm.bytecode.object };
}

async function main() {
  const privateKey = process.env.DEPLOYER_PRIVATE_KEY;
  const alchemyKey = process.env.NEXT_PUBLIC_ALCHEMY_API_KEY;
  const mintSigner = process.env.MINT_SIGNER_ADDRESS;
  const baseURI = process.env.BASE_URI ?? "https://proof-of-dev.vercel.app/api/token";

  if (!privateKey || !alchemyKey || !mintSigner) {
    console.error(
      "Missing env. Required: DEPLOYER_PRIVATE_KEY, NEXT_PUBLIC_ALCHEMY_API_KEY, MINT_SIGNER_ADDRESS"
    );
    process.exit(1);
  }
  if (!ethers.isAddress(mintSigner)) {
    console.error(`MINT_SIGNER_ADDRESS is not a valid address: ${mintSigner}`);
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(
    `https://eth-sepolia.g.alchemy.com/v2/${alchemyKey}`
  );
  const wallet = new ethers.Wallet(privateKey, provider);

  console.log("Compiling", CONTRACT_FILE, "...");
  const { abi, bytecode } = compile();
  console.log("Compiled. Bytecode size:", (bytecode.length - 2) / 2, "bytes");

  console.log("Deployer:", wallet.address);
  const balance = await provider.getBalance(wallet.address);
  console.log("Balance:", ethers.formatEther(balance), "ETH");
  if (balance === 0n) {
    console.error("No Sepolia ETH. Fund the deployer: https://www.alchemy.com/faucets/ethereum-sepolia");
    process.exit(1);
  }

  console.log("Mint signer:", mintSigner);
  console.log("Base URI:", baseURI);

  const factory = new ethers.ContractFactory(abi, bytecode, wallet);
  console.log("Deploying ProofOfDevV2 ...");
  const contract = await factory.deploy(baseURI, mintSigner);
  await contract.waitForDeployment();
  const address = await contract.getAddress();

  // Pre-encode constructor args for manual Etherscan verification if needed.
  const encodedArgs = ethers.AbiCoder.defaultAbiCoder()
    .encode(["string", "address"], [baseURI, mintSigner])
    .slice(2);

  console.log("\n✅ ProofOfDevV2 deployed to:", address);
  console.log("\nAdd to .env.local:");
  console.log(`NEXT_PUBLIC_CONTRACT_ADDRESS_V2=${address}`);
  console.log("\nVerify on Etherscan with Foundry:");
  console.log(
    `  forge verify-contract ${address} contracts/ProofOfDevV2.sol:ProofOfDevV2 \\\n` +
      `    --chain sepolia --watch \\\n` +
      `    --constructor-args ${"0x" + encodedArgs}`
  );
  console.log("\nExplorer:");
  console.log(`  https://sepolia.etherscan.io/address/${address}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
