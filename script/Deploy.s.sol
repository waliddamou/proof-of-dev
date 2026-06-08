// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ProofOfDevV2} from "../contracts/ProofOfDevV2.sol";

/**
 * @title Deploy ProofOfDevV2 to an EVM testnet (Sepolia).
 *
 * @dev One-command deploy + Etherscan verification.
 *
 * Env vars:
 *   DEPLOYER_PRIVATE_KEY  — deployer wallet (needs testnet ETH for gas)
 *   MINT_SIGNER_ADDRESS   — the trusted voucher signer address (server)
 *   BASE_URI              — token metadata base URI (optional; has a default)
 *   ALCHEMY_API_KEY       — used by the `sepolia` rpc_endpoint in foundry.toml
 *   ETHERSCAN_API_KEY     — used by --verify
 *
 * Run (deploy + verify):
 *   forge script script/Deploy.s.sol:DeployProofOfDevV2 \
 *     --rpc-url sepolia --broadcast --verify -vvvv
 *
 * Dry run (no broadcast):
 *   forge script script/Deploy.s.sol:DeployProofOfDevV2 --rpc-url sepolia
 */
contract DeployProofOfDevV2 is Script {
    function run() external returns (ProofOfDevV2 pod) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address mintSigner = vm.envAddress("MINT_SIGNER_ADDRESS");
        string memory baseURI =
            vm.envOr("BASE_URI", string("https://proof-of-dev.vercel.app/api/token"));

        require(mintSigner != address(0), "MINT_SIGNER_ADDRESS not set");

        console2.log("Deployer:", vm.addr(deployerKey));
        console2.log("Mint signer:", mintSigner);
        console2.log("Base URI:", baseURI);

        vm.startBroadcast(deployerKey);
        pod = new ProofOfDevV2(baseURI, mintSigner);
        vm.stopBroadcast();

        console2.log("ProofOfDevV2 deployed at:", address(pod));
        console2.log("Set NEXT_PUBLIC_CONTRACT_ADDRESS_V2=", address(pod));
    }
}
