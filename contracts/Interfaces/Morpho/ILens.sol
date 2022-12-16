// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface ILens {
    function getUserUnclaimedRewards(
        address[] calldata _poolTokenAddresses,
        address _user
    ) external view returns (uint256 unclaimedRewards);

    function getCurrentSupplyBalanceInOf(
        address _poolTokenAddress,
        address _user
    )
        external
        view
        returns (
            uint256 balanceOnPool,
            uint256 balanceInP2P,
            uint256 totalBalance
        );

    function getMainMarketData(address _poolTokenAddress)
        external
        view
        returns (
            uint256 avgSupplyRatePerBlock,
            uint256 avgBorrowRatePerBlock,
            uint256 p2pSupplyAmount,
            uint256 p2pBorrowAmount,
            uint256 poolSupplyAmount,
            uint256 poolBorrowAmount
        );

    // only for Aave
    function getNextUserSupplyRatePerYear(
        address _poolTokenAddress,
        address _user,
        uint256 _amount
    )
        external
        view
        returns (
            uint256 nextSupplyRatePerYear,
            uint256 balanceInP2P,
            uint256 balanceOnPool,
            uint256 totalBalance
        );

    // only for Aave
    function getCurrentUserSupplyRatePerYear(
        address _poolTokenAddress,
        address _user
    )
        external
        view
        returns (
            uint256 supplyRatePerYear
        );
}
