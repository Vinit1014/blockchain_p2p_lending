
pragma solidity ^0.5.0;

import './common/SafeMath.sol';
import './common/Destructible.sol';

/** @title Credit contract.
  * Inherits the Ownable and Destructible contracts.
  */
contract Credit is Destructible {

    /** @dev Usings */
    // Using SafeMath for our calculations with uints.
    using SafeMath for uint;

    /** @dev State variables */
    // Borrower is the person who generated the credit contract.
    address payable public borrower;

    address public owner;
    // Amount requested to be funded (in wei).
    uint public requestedAmount;

    // Amount that will be returned by the borrower (including the interest).
    uint public returnAmount;

    // Currently repaid amount.
    uint public repaidAmount;

    // Credit interest.
    uint public interest;

    // Requested number of repayment installments.
    uint public requestedRepayments;

    // Remaining repayment installments.
    uint public remainingRepayments;

    // The value of the repayment installment.
    uint public repaymentInstallment;

    // The timestamp of credit creation.
    uint public requestedDate;

    // The timestamp of last repayment date.
    uint public lastRepaymentDate;

    // Description of the credit.
    bytes32 public description;

    // Active state of the credit.
    bool public active = true;

    /** Stages that every credit contract gets through.
      *   investment - During this state only investments are allowed.
      *   repayment - During this stage only repayments are allowed.
      *   interestReturns - This stage gives investors opportunity to request their returns.
      *   expired - This is the stage when the contract is finished its purpose.
      *   fraud - The borrower was marked as fraud.
    */
    enum State { investment, repayment, interestReturns, expired, revoked, fraud }
    State public state;

    // Storing the lenders for this credit.
    mapping(address => bool) public lenders;

    // Storing the invested amount by each lender.
    mapping(address => uint) public lendersInvestedAmount;

    // Store the lenders count, later needed for revoke vote.
    uint public lendersCount = 0;

    // Revoke votes count.
    uint public revokeVotes = 0;

    // Revoke voters.
    mapping(address => bool) public revokeVoters;

    // Time needed for a revoke voting to start.
    // To be changed in production accordingly.
    uint public revokeTimeNeeded = block.timestamp + 1 seconds;

    // Fraud votes count.
    uint public fraudVotes = 0;

    // Fraud voters.
    mapping(address => bool) public fraudVoters;

    /** @dev Events */
    event LogCreditInitialized(address indexed _address, uint indexed timestamp);
    event LogCreditStateChanged(State indexed state, uint indexed timestamp);
    event LogCreditStateActiveChanged(bool indexed active, uint indexed timestamp);

    event LogBorrowerWithdrawal(address indexed _address, uint indexed _amount, uint indexed timestamp);
    event LogBorrowerRepaymentInstallment(address indexed _address, uint indexed _amount, uint indexed timestamp);
    event LogBorrowerRepaymentFinished(address indexed _address, uint indexed timestamp);
    event LogBorrowerChangeReturned(address indexed _address, uint indexed _amount, uint indexed timestamp);
    event LogBorrowerIsFraud(address indexed _address, bool indexed fraudStatus, uint indexed timestamp);

    event LogLenderInvestment(address indexed _address, uint indexed _amount, uint indexed timestamp);
    event LogLenderWithdrawal(address indexed _address, uint indexed _amount, uint indexed timestamp);
    event LogLenderChangeReturned(address indexed _address, uint indexed _amount, uint indexed timestamp);
    event LogLenderVoteForRevoking(address indexed _address, uint indexed timestamp);
    event LogLenderVoteForFraud(address indexed _address, uint indexed timestamp);
    event LogLenderRefunded(address indexed _address, uint indexed _amount, uint indexed timestamp);

    /** @dev Modifiers */
    modifier isActive() {
        require(active == true);
        _;
    }

    modifier onlyBorrower() {
        require(msg.sender == borrower);
        _;
    }

    modifier onlyLender() {
        require(lenders[msg.sender] == true);
        _;
    }

    modifier canAskForInterest() {
        require(state == State.interestReturns);
        require(lendersInvestedAmount[msg.sender] > 0);
        _;
    }

    modifier canInvest() {
        require(state == State.investment);
        _;
    }

    modifier canRepay() {
        require(state == State.repayment);
        _;
    }

    modifier canWithdraw() {
        require(address(this).balance >= requestedAmount);
        _;
    }

    modifier isNotFraud() {
        require(state != State.fraud);
        _;
    }

    modifier isRevokable() {
        require(block.timestamp >= revokeTimeNeeded);
        require(state == State.investment);
        _;
    }

    modifier isRevoked() {
        require(state == State.revoked);
        _;
    }

    /** @dev Constructor.
      * @param _requestedAmount Requested credit amount (in wei).
      * @param _requestedRepayments Requested number of repayments.
      * @param _interest Credit interest.
      * @param _description Credit description.
      */
    constructor(
        uint _requestedAmount,
        uint _requestedRepayments,
        uint _interest,
        bytes32 _description
    ) public {
        /** Set the borrower of the contract to the tx.origin
          * We are using tx.origin, because the contract is going to be published
          * by the main contract and msg.sender will break our logic.
        */
        borrower = address(uint160(tx.origin)); // Convert to address payable

        // Set the interest for the credit.
        interest = _interest;

        // Set the requested amount.
        requestedAmount = _requestedAmount;

        // Set the requested repayments.
        requestedRepayments = _requestedRepayments;

        /** Set the remaining repayments.
          * Initially this is equal to the requested repayments.
          */
        remainingRepayments = _requestedRepayments;

        /** Calculate the amount to be returned by the borrower.
          * At this point this is the addition of the requested amount and the interest.
          */
        returnAmount = requestedAmount.add(interest);

        /** Calculating the repayment installment.
          * We divide the amount to be returned by the requested repayments count to get it.
          */
        repaymentInstallment = returnAmount.div(requestedRepayments);

        // Set the credit description.
        description = _description;

        // Set the initialization date.
        requestedDate = block.timestamp;

        // Set initial state
        state = State.investment;

        // Log credit initialization.
        emit LogCreditInitialized(borrower, block.timestamp);
    }

    /** @dev Get current balance.
      * @return uint256 Current contract balance.
      */
    function getBalance() public view returns (uint256) {
        return address(this).balance;
    }

    /** @dev Invest function.
      * Provides functionality for person to invest in someone's credit,
      * incentivised by the return of interest.
      */
    function invest() public canInvest payable {
        // Initialize a memory variable for the extra money that may have been sent.
        uint extraMoney = 0;

        // Check if contract balance is reached the requested amount.
        if (address(this).balance >= requestedAmount) {
            // Calculate the extra money that may have been sent.
            extraMoney = address(this).balance.sub(requestedAmount);

            // Assert the calculations
            assert(requestedAmount == address(this).balance.sub(extraMoney));

            // Assert for possible underflow / overflow
            assert(extraMoney <= msg.value);

            // Check if extra money is greater than 0 wei.
            if (extraMoney > 0) {
                // Return the extra money to the sender.
                address(uint160(msg.sender)).transfer(extraMoney);

                // Log change returned.
                emit LogLenderChangeReturned(msg.sender, extraMoney, block.timestamp);
            }

            // Set the contract state to repayment.
            state = State.repayment;

            // Log state change.
            emit LogCreditStateChanged(state, block.timestamp);
        }

        /** Add the investor to the lenders mapping.
          * So that we know they invested in this contract.
          */
        lenders[msg.sender] = true;

        // Increment the lenders count.
        lendersCount++;

        // Add the amount invested to the amount mapping.
        lendersInvestedAmount[msg.sender] = lendersInvestedAmount[msg.sender].add(msg.value.sub(extraMoney));

        // Log lender invested amount.
        emit LogLenderInvestment(msg.sender, msg.value.sub(extraMoney), block.timestamp);
    }

    /** @dev Repayment function.
      * Allows borrower to make repayment installments.
      */
    function repay() public onlyBorrower canRepay payable {
        // The remaining repayments should be greater than 0 to continue.
        require(remainingRepayments > 0);

        // The value sent should be greater than the repayment installment.
        require(msg.value >= repaymentInstallment);

        /** Assert that the amount to be returned is greater
          * than the sum of repayments made until now.
          * Otherwise the credit is already repaid.
          */
        assert(repaidAmount < returnAmount);

        // Decrement the remaining repayments.
        remainingRepayments--;

        // Update last repayment date.
        lastRepaymentDate = block.timestamp;

        // Initialize a memory variable for the extra money that may have been sent.
        uint extraMoney = 0;

        /** Check if the value (in wei) that is being sent is greater than the repayment installment.
          * In this case we should return the change to the msg.sender.
          */
        if (msg.value > repaymentInstallment) {
            // Calculate the extra money being sent in the transaction.
            extraMoney = msg.value.sub(repaymentInstallment);

            // Assert the calculations.
            assert(repaymentInstallment == msg.value.sub(extraMoney));

            // Assert for underflow.
            assert(extraMoney <= msg.value);

            // Return the change/extra money to the msg.sender.
            msg.sender.transfer(extraMoney);

            // Log the return of the extra money.
            emit LogBorrowerChangeReturned(msg.sender, extraMoney, block.timestamp);
        }

        // Log borrower installment received.
        emit LogBorrowerRepaymentInstallment(msg.sender, msg.value.sub(extraMoney), block.timestamp);

        // Add the repayment installment amount to the total repaid amount.
        repaidAmount = repaidAmount.add(msg.value.sub(extraMoney));

        // Check the repaid amount reached the amount to be returned.
        if (repaidAmount == returnAmount) {
            // Log credit repaid.
            emit LogBorrowerRepaymentFinished(msg.sender, block.timestamp);

            // Set the credit state to "returning interests".
            state = State.interestReturns;

            // Log state change.
            emit LogCreditStateChanged(state, block.timestamp);
        }
    }

    /** @dev Withdraw function.
      * It can only be executed while contract is in active state.
      * It is only accessible to the borrower.
      * It is only accessible if the needed amount is gathered in the contract.
      * It can only be executed once.
      * Transfers the gathered amount to the borrower.
      */
    function withdraw() public isActive onlyBorrower canWithdraw isNotFraud {
        // Set the state to repayment so we can avoid reentrancy.
        state = State.repayment;

        // Log state change.
        emit LogCreditStateChanged(state, block.timestamp);

        // Log borrower withdrawal.
        emit LogBorrowerWithdrawal(msg.sender, address(this).balance, block.timestamp);

        // Transfer the gathered amount to the credit borrower.
        borrower.transfer(address(this).balance);
    }

    /** @dev Request interest function.
      * It can only be executed while contract is in active state.
      * It is only accessible to lenders.
      * It is only accessible if lender funded 1 or more wei.
      * It can only be executed once.
      * Transfers the lended amount + interest to the lender.
      */
    function requestInterest() public isActive onlyLender canAskForInterest {
        // Calculate the amount to be returned to lender.
        uint lenderReturnAmount = returnAmount.div(lendersCount);

        // Assert the contract has enough balance to pay the lender.
        assert(address(this).balance >= lenderReturnAmount);

        // Transfer the return amount with interest to the lender.
        address(uint160(msg.sender)).transfer(lenderReturnAmount);

        // Log the transfer to lender.
        emit LogLenderWithdrawal(msg.sender, lenderReturnAmount, block.timestamp);

        // Check if the contract balance is drawn.
        if (address(this).balance == 0) {
            // Set the active state to false.
            active = false;

            // Log active state change.
            emit LogCreditStateActiveChanged(active, block.timestamp);

            // Set the contract stage to expired e.g. its lifespan is over.
            state = State.expired;

            // Log state change.
            emit LogCreditStateChanged(state, block.timestamp);
        }
    }

    /** @dev Function to get the whole credit information. */
    function getCreditInfo() public view returns (
        address,
        bytes32,
        uint,
        uint,
        uint,
        uint,
        uint,
        uint,
        State,
        bool,
        uint
    ) {
        return (
            borrower,
            description,
            requestedAmount,
            requestedRepayments,
            repaymentInstallment,
            remainingRepayments,
            interest,
            returnAmount,
            state,
            active,
            address(this).balance
        );
    }

    /** @dev Function for revoking the credit. */
    function revokeVote() public isActive isRevokable onlyLender {
        // Require only one vote per lender.
        require(revokeVoters[msg.sender] == false);

        // Increment the revokeVotes.
        revokeVotes++;

        // Note the lender has voted.
        revokeVoters[msg.sender] = true;

        // Log lender vote for revoking the credit contract.
        emit LogLenderVoteForRevoking(msg.sender, block.timestamp);

        // If the consensus is reached.
        if (lendersCount == revokeVotes) {
            // Call internal revoke function.
            revoke();
        }
    }

    /** @dev Revoke internal function. */
    function revoke() internal {
        // Change the state to revoked.
        state = State.revoked;

        // Log credit revoked.
        emit LogCreditStateChanged(state, block.timestamp);
    }

    /** @dev Function for refunding people. */
    function refund() public isActive onlyLender isRevoked {
        // assert the contract has enough balance.
        assert(address(this).balance >= lendersInvestedAmount[msg.sender]);

        // Transfer the return amount with interest to the lender.
        address(uint160(msg.sender)).transfer(lendersInvestedAmount[msg.sender]);

        // Log the transfer to lender.
        emit LogLenderRefunded(msg.sender, lendersInvestedAmount[msg.sender], block.timestamp);

        // Check if the contract balance is drawn.
        if (address(this).balance == 0) {
            // Set the active state to false.
            active = false;

            // Log active status change.
            emit LogCreditStateActiveChanged(active, block.timestamp);

            // Set the contract stage to expired e.g. its lifespan is over.
            state = State.expired;

            // Log state change.
            emit LogCreditStateChanged(state, block.timestamp);
        }
    }

    /** @dev Function for voting the borrower as fraudster. */
    function fraudVote() public isActive onlyLender returns (bool) {
        // A lender could vote only once.
        require(fraudVoters[msg.sender] == false);

        // Increment fraudVotes count.
        fraudVotes++;

        // Note the lender has voted.
        fraudVoters[msg.sender] = true;  // Fixed: Changed == to =

        // Log lenders vote for fraud
        emit LogLenderVoteForFraud(msg.sender, block.timestamp);

        // Check if consensus is reached.
        if (lendersCount == fraudVotes) {
            // Invoke fraud function.
            return fraud();
        }
        return true;
    }

    /** @dev Fraud function
      * @return bool indicating if the fraud status was set successfully
      * calls the owner contract and marks the borrower as fraudster.
      */
    function fraud() internal returns (bool) {
    // Create the function signature for setFraudStatus
        bytes memory payload = abi.encodeWithSignature("setFraudStatus(address)", borrower);
        
        // Use the owner address directly (assuming owner is a state variable)
        (bool success, ) = owner.call(payload);

        // Set the state to fraud if the call was successful
        if (success) {
            state = State.fraud;
        }

        // Log user marked as fraud
        emit LogBorrowerIsFraud(borrower, success, block.timestamp);

        return success;
    }

    /** @dev Change state function.
      * @param _state New state.
      * Only accessible to the owner of the contract.
      * Changes the state of the contract.
      */
    function changeState(State _state) external onlyOwner returns (uint) {
        state = _state;

        // Log state change.
        emit LogCreditStateChanged(state, block.timestamp);

        return uint(state);
    }

    /** @dev Toggle active state function.
      * Only accessible to the owner of the contract.
      * Toggles the active state of the contract.
      * @return bool
      */
    function toggleActive() external onlyOwner returns (bool) {
        active = !active;

        // Log active status change.
        emit LogCreditStateActiveChanged(active, block.timestamp);

        return active;
    }
}

