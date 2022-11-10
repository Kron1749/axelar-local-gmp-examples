'use strict';

const {
    getDefaultProvider,
    Contract,
    constants: { AddressZero },
} = require('ethers');
const {
    utils: { deployContract },
} = require('@axelar-network/axelar-local-dev');

const { sleep } = require('../../utils');
const DistributionExecutable = require('../../artifacts/examples/call-contract-with-token/DistributionExecutable.sol/DistributionExecutable.json');
const Gateway = require('../../artifacts/@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol/IAxelarGateway.json');
const IERC20 = require('../../artifacts/@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IERC20.sol/IERC20.json');
const Treasury = require('../../artifacts/examples/call-contract-with-token/Treasury.sol/Treasury.json');

async function deploy(chain, wallet) {
    console.log(`Deploying Slot for ${chain.name}.`);
    const treasury = await deployContract(wallet,Treasury)
    console.log(treasury.address)
    const contract = await deployContract(wallet, DistributionExecutable, [
        chain.gateway,
        chain.gasReceiver,
        treasury.address,
        treasury.address, 
        wallet.address,
        wallet.address,
        '0xc2fa98fab811b785b81c64ac875b31cc9e40f9d2',
        10,
    ]);
    chain.distributionExecutable = contract.address;
    chain.treasury = treasury.address
    console.log(`Deployed Slot for ${chain.name} at ${chain.distributionExecutable}.`);
    console.log(`Deployed Treasury for ${chain.name} at ${chain.treasury}.`);
}

async function test(chains, wallet, options) {


    const args = options.args || [];
    const getGasPrice = options.getGasPrice;
    const source = chains.find((chain) => chain.name === 'Avalanche');
    const destination = chains.find((chain) => chain.name === (args[1] || 'Fantom'));
    const amount = Math.floor(parseFloat(args[2])) * 1e6 || 10e6;
    const accounts = args.slice(3);
    
    for (const chain of [source, destination]) {
        const provider = getDefaultProvider(chain.rpc);
        chain.wallet = wallet.connect(provider);
        chain.contract = new Contract(chain.distributionExecutable, DistributionExecutable.abi, chain.wallet);
        chain.treasury = new Contract(chain.treasury,Treasury.abi,chain.wallet)
        chain.gateway = new Contract(chain.gateway, Gateway.abi, chain.wallet);
        const usdcAddress = chain.gateway.tokenAddresses('aUSDC');
        chain.usdc = new Contract(usdcAddress, IERC20.abi, chain.wallet);
    }

    const treasuryAddress = await source.treasury.address
    console.log(treasuryAddress)

    if (accounts.length === 0) accounts.push(treasuryAddress);
    await source.usdc.transfer(source.contract.address,10000000)
    const balanceOfTreausryBeforeSource = (await source.usdc.balanceOf(treasuryAddress))
    const balanceOfTreausryBeforDestination = (await destination.usdc.balanceOf(treasuryAddress))
    const balanceOnSlotBeforeSource = (await source.usdc.balanceOf(source.contract.address))
    const balanceOnSlotBeforeDestination = (await destination.usdc.balanceOf(destination.contract.address))
    const balanceOnWalletBeforeSource = (await source.usdc.balanceOf(wallet.address))
    const balanceOnWalletBeforeDestination = (await destination.usdc.balanceOf(wallet.address))
    console.log(`balanceOnTreasuryBeforeSource on ${source.name} is ${balanceOfTreausryBeforeSource}`)
    console.log(`balanceOnTreasuryBeforeDestination on ${destination.name} is ${balanceOfTreausryBeforDestination}`)
    console.log(`balanceOnSlotBeforeSource on ${source.name} is ${balanceOnSlotBeforeSource}`)
    console.log(`balanceOnSlotBeforeDestination on ${destination.name} is ${balanceOnSlotBeforeDestination}`)
    console.log(`balanceOnWalletBeforeSource on ${source.name} is ${balanceOnWalletBeforeSource}`)
    console.log(`balanceOnWalletBeforeDestination on ${destination.name} is ${balanceOnWalletBeforeDestination}`)
    const balance = BigInt(await destination.usdc.balanceOf(accounts[0]));
    const approveTx = await source.usdc.approve(source.contract.address, amount);
    await approveTx.wait();
    // const Allowance = await source.usdc.allowance(source.contract.address,amount)
    // await increaseAllowance.wait()

    const gasLimit = 3e6;
    const gasPrice = await getGasPrice(source, destination, AddressZero);
    // const sendTx = await source.contract.test(destination.contract.address, accounts, 'aUSDC', amount,{
    //     value: BigInt(Math.floor(gasLimit * gasPrice)),
    // });
    console.log(destination.contract.address)
    console.log(treasuryAddress)
    const sendTx = await source.contract.claimTreasury(amount,{
        value: BigInt(Math.floor(gasLimit * gasPrice)),
    })

    await sendTx.wait();

       while (BigInt(await destination.usdc.balanceOf(accounts[0])) === balance) {
        await sleep(2000);
    }

    console.log("AFTER --------")
    const balanceOfTreausryAfterSource = (await source.usdc.balanceOf(treasuryAddress))
    const balanceOfTreausryAfterDestination = (await destination.usdc.balanceOf(treasuryAddress))
    const balanceOnSlotAfterSource = (await source.usdc.balanceOf(source.contract.address))
    const balanceOnSlotAfterDestination = (await destination.usdc.balanceOf(destination.contract.address))
    const balanceOnWalletAfterSource = (await source.usdc.balanceOf(wallet.address))
    const balanceOnWalletAfterDestination = (await destination.usdc.balanceOf(wallet.address))
    console.log(`balanceOnTreasuryAfterSource on ${source.name} is ${balanceOfTreausryAfterSource}`)
    console.log(`balanceOfTreausryAfterDestination on ${destination.name} is ${balanceOfTreausryAfterDestination}`)
    console.log(`balanceOnSlotAfterSource on ${source.name} is ${balanceOnSlotAfterSource}`)
    console.log(`balanceOnSlotAfterDestination on ${destination.name} is ${balanceOnSlotAfterDestination}`)
    console.log(`balanceOnWalletAfterSource on ${source.name} is ${balanceOnWalletAfterSource}`)
    console.log(`balanceOnWalletAfterDestination on ${destination.name} is ${balanceOnWalletAfterDestination}`)
}

module.exports = {
    deploy,
    test,
};
