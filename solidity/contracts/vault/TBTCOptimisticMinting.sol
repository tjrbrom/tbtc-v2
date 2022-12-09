// SPDX-License-Identifier: GPL-3.0-only

// ██████████████     ▐████▌     ██████████████
// ██████████████     ▐████▌     ██████████████
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
// ██████████████     ▐████▌     ██████████████
// ██████████████     ▐████▌     ██████████████
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌

pragma solidity 0.8.17;

import "../bridge/Bridge.sol";
import "../bridge/Deposit.sol";

abstract contract TBTCOptimisticMinting is Ownable {
    // TODO: make it governable?
    uint256 public constant OPTIMISTIC_MINTING_DELAY = 3 hours;

    Bridge public bridge;

    mapping(address => bool) public isMinter;
    mapping(address => bool) public isGuard;

    mapping(uint256 => uint256) public pendingOptimisticMints;

    mapping(address => uint256) public optimisticMintingDebt;

    event OptimisticMintingRequested(
        address indexed minter,
        bytes32 fundingTxHash,
        uint32 fundingOutputIndex,
        uint256 depositKey
    );
    event OptimisticMintingFinalized(
        address indexed minter,
        bytes32 fundingTxHash,
        uint32 fundingOutputIndex,
        uint256 depositKey
    );
    event OptimisticMintingCancelled(
        address indexed guard,
        bytes32 fundingTxHash,
        uint32 fundingOutputIndex,
        uint256 depositKey
    );
    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);
    event GuardAdded(address indexed guard);
    event GuardRemoved(address indexed guard);

    modifier onlyMinter() {
        require(isMinter[msg.sender], "Caller is not a minter");
        _;
    }

    modifier onlyGuard() {
        require(isGuard[msg.sender], "Caller is not a guard");
        _;
    }

    constructor(Bridge _bridge) {
        require(
            address(_bridge) != address(0),
            "Bridge can not be the zero address"
        );

        bridge = _bridge;
    }

    function _mint(address minter, uint256 amount) internal virtual;

    function optimisticMint(bytes32 fundingTxHash, uint32 fundingOutputIndex)
        external
        onlyMinter
    {
        uint256 depositKey = calculateDepositKey(
            fundingTxHash,
            fundingOutputIndex
        );
        Deposit.DepositRequest memory deposit = bridge.deposits(depositKey);

        // TODO: validate when it was revealed?

        require(deposit.revealedAt != 0, "The deposit has not been revealed");
        require(deposit.sweptAt == 0, "The deposit is already swept");
        require(deposit.vault == address(this), "Unexpected vault address");

        /* solhint-disable-next-line not-rely-on-time */
        pendingOptimisticMints[depositKey] = block.timestamp;

        emit OptimisticMintingRequested(
            msg.sender,
            fundingTxHash,
            fundingOutputIndex,
            depositKey
        );
    }

    function finalizeOptimisticMint(
        bytes32 fundingTxHash,
        uint32 fundingOutputIndex
    ) external onlyMinter {
        uint256 depositKey = calculateDepositKey(
            fundingTxHash,
            fundingOutputIndex
        );

        uint256 requestedAt = pendingOptimisticMints[depositKey];
        require(
            requestedAt != 0,
            "Optimistic minting not requested or already finalized"
        );
        require(
            /* solhint-disable-next-line not-rely-on-time */
            block.timestamp - requestedAt > OPTIMISTIC_MINTING_DELAY,
            "Optimistic minting delay has not passed yet"
        );

        Deposit.DepositRequest memory deposit = bridge.deposits(depositKey);
        require(deposit.sweptAt == 0, "The deposit is already swept");

        // TODO: deal with the minting fee
        _mint(deposit.depositor, deposit.amount);
        optimisticMintingDebt[deposit.depositor] += deposit.amount;

        delete pendingOptimisticMints[depositKey];

        emit OptimisticMintingFinalized(
            msg.sender,
            fundingTxHash,
            fundingOutputIndex,
            depositKey
        );
    }

    // TODO: Is this function convenient enough to block minting at 3AM ?
    //       Do we want to give watchment a chance to temporarily disable
    //       finalizeOptimisticMint ?
    function cancelOptimisticMint(
        bytes32 fundingTxHash,
        uint32 fundingOutputIndex
    ) external onlyGuard {
        uint256 depositKey = calculateDepositKey(
            fundingTxHash,
            fundingOutputIndex
        );

        require(
            pendingOptimisticMints[depositKey] > 0,
            "Optimistic minting not requested of already finalized"
        );

        delete pendingOptimisticMints[depositKey];

        emit OptimisticMintingCancelled(
            msg.sender,
            fundingTxHash,
            fundingOutputIndex,
            depositKey
        );
    }

    function addMinter(address minter) external onlyOwner {
        require(!isMinter[minter], "This address is already a minter");
        isMinter[minter] = true;
        emit MinterAdded(minter);
    }

    function removeMinter(address minter) external onlyOwner {
        require(isMinter[minter], "This address is not a minter");
        delete isMinter[minter];
        emit MinterRemoved(minter);
    }

    function addGuard(address guard) external onlyOwner {
        require(!isGuard[guard], "This address is already a guard");
        isGuard[guard] = true;
        emit GuardAdded(guard);
    }

    function removeGuard(address guard) external onlyOwner {
        require(isGuard[guard], "This address is not a guard");
        delete isGuard[guard];
        emit GuardRemoved(guard);
    }

    function calculateDepositKey(
        bytes32 fundingTxHash,
        uint32 fundingOutputIndex
    ) public view returns (uint256) {
        return
            uint256(
                keccak256(abi.encodePacked(fundingTxHash, fundingOutputIndex))
            );
    }

    function repayOptimisticMintDebt(address depositor, uint256 amount)
        internal
        returns (uint256)
    {
        uint256 debt = optimisticMintingDebt[depositor];

        if (amount > debt) {
            optimisticMintingDebt[depositor] = 0;
            return amount - debt;
        } else {
            optimisticMintingDebt[depositor] -= amount;
            return 0;
        }

        // TODO: emit an event
    }
}
