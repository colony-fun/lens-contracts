// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITotalData {
    function setFreeAvatarMinted(address _address) external;
    function freeAvatarMinted(address _address) external view returns (bool);

    function setFreeLandMinted(address _address) external;
    function freeLandMinted(address _address) external view returns (bool);

    function whitelisted(address _address) external view returns (bool);
}
