pragma solidity ^0.5.0;

import './Ownable.sol';

contract Destructible is Ownable {
    
    constructor() public payable { }

    function destroy() public onlyOwner {
        selfdestruct(address(uint160(owner)));
    }
    
    function destroyAndSend(address _recipient) public onlyOwner {
        selfdestruct(address(uint160(_recipient)));
    }
}