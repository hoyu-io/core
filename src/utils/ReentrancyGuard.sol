// SPDX-License-Identifier: MIT

pragma solidity =0.8.21;

// Modified from OpenZeppelin (https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/ReentrancyGuard.sol)

abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
    }

    modifier nonReentrant() {
        _nonReentrantLock();
        _;
        _nonReentrantUnlock();
    }

    // renamed and made internal
    function _nonReentrantLock() internal {
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        _status = ENTERED;
    }

    // renamed and made internal
    function _nonReentrantUnlock() internal {
        _status = NOT_ENTERED;
    }
}
