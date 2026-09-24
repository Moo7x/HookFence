// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

interface IOpenMint {
    function mint(address to, uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
}

/// @title Give the two demo user wallets gas and stablecoin
///
/// @notice The faucet funds one address: the deployer. That key owns the
///         contracts and writes the price feeds, so it is kept out of the user
///         journey entirely. This moves a little test ETH from it to Alice and
///         Bob, and mints each some rUSDG (whose mint is open to anyone).
///
/// @dev Amounts come from receipts measured on a testnet fork: one full journey
///      costs about 0.0000227 ETH. Alice gets room for several, Bob for a few.
///
///        forge script script/FundTestnetWallets.s.sol \
///          --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast --slow
contract FundTestnetWallets is Script {
    uint256 constant ALICE_ETH = 0.0002 ether;
    uint256 constant BOB_ETH = 0.0001 ether;
    uint256 constant RUSDG_EACH = 200_000000; // 200 rUSDG

    function run() external {
        require(block.chainid == 46630, "not Robinhood Chain testnet");
        string memory json = vm.readFile("./reports/jayo-testnet.json");
        address rusdg = vm.parseJsonAddress(json, ".usdg");

        address alice = vm.envAddress("ALICE_ADDRESS");
        address bob = vm.envAddress("BOB_ADDRESS");
        require(alice != bob, "Alice and Bob must be different wallets");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        require(vm.addr(pk) != alice && vm.addr(pk) != bob, "the deployer must not be a demo user");

        vm.startBroadcast(pk);
        payable(alice).transfer(ALICE_ETH);
        payable(bob).transfer(BOB_ETH);
        IOpenMint(rusdg).mint(alice, RUSDG_EACH);
        IOpenMint(rusdg).mint(bob, RUSDG_EACH);
        vm.stopBroadcast();

        console2.log("Alice", alice);
        console2.log("Bob  ", bob);
    }
}
