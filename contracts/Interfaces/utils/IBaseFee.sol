// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}
