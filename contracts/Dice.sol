pragma solidity ^0.4.11;
import "./usingOraclize.sol";

contract Dice is usingOraclize {
    uint256 public pwin = 5000; //probability of winning (10000 = 100%)
    uint256 public edge = 200; //edge percentage (10000 = 100%)
    uint256 public maxWin = 100; //max win (before edge is taken) as percentage of bankroll (10000 = 100%)
    uint256 public minBet = 1 finney;
    uint256 public maxInvestors = 5; //maximum number of investors
    uint256 public houseEdge = 50; //edge percentage (10000 = 100%)
    uint256 public divestFee = 50; //divest fee percentage (10000 = 100%)
    uint256 public emergencyWithdrawalRatio = 90; //ratio percentage (100 = 100%)

    uint256 safeGas = 25000;
    uint256 constant ORACLIZE_GAS_LIMIT = 125000;
    uint256 constant INVALID_BET_MARKER = 99999;
    uint256 constant EMERGENCY_TIMEOUT = 7 days;

    struct Investor {
        address investorAddress;
        uint256 amountInvested;
        bool votedForEmergencyWithdrawal;
    }

    struct Bet {
        address playerAddress;
        uint256 amountBetted;
        uint256 numberRolled;
    }

    struct WithdrawalProposal {
        address toAddress;
        uint256 atTime;
    }

    //Starting at 1
    mapping(address => uint256) public investorIDs;
    mapping(uint256 => Investor) public investors;
    uint256 public numInvestors = 0;

    uint256 public invested = 0;

    address owner;
    address houseAddress;
    bool public isStopped;

    WithdrawalProposal public proposedWithdrawal;

    mapping(bytes32 => Bet) bets;
    bytes32[] betsKeys;

    uint256 public amountWagered = 0;
    uint256 public investorsProfit = 0;
    uint256 public investorsLoses = 0;
    bool profitDistributed;

    event BetWon(
        address playerAddress,
        uint256 numberRolled,
        uint256 amountWon
    );
    event BetLost(address playerAddress, uint256 numberRolled);
    event EmergencyWithdrawalProposed();
    event EmergencyWithdrawalFailed(address withdrawalAddress);
    event EmergencyWithdrawalSucceeded(
        address withdrawalAddress,
        uint256 amountWithdrawn
    );
    event FailedSend(address receiver, uint256 amount);
    event ValueIsTooBig();

    function Dice(
        uint256 pwinInitial,
        uint256 edgeInitial,
        uint256 maxWinInitial,
        uint256 minBetInitial,
        uint256 maxInvestorsInitial,
        uint256 houseEdgeInitial,
        uint256 divestFeeInitial,
        uint256 emergencyWithdrawalRatioInitial
    ) {
        OAR = OraclizeAddrResolverI(0x6f485C8BF6fc43eA212E93BBF8ce046C7f1cb475);
        oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);

        pwin = pwinInitial;
        edge = edgeInitial;
        maxWin = maxWinInitial;
        minBet = minBetInitial;
        maxInvestors = maxInvestorsInitial;
        houseEdge = houseEdgeInitial;
        divestFee = divestFeeInitial;
        emergencyWithdrawalRatio = emergencyWithdrawalRatioInitial;
        owner = msg.sender;
        houseAddress = msg.sender;
    }

    //SECTION I: MODIFIERS AND HELPER FUNCTIONS

    //MODIFIERS

    modifier onlyIfNotStopped {
        if (isStopped) throw;
        _;
    }

    modifier onlyIfStopped {
        if (!isStopped) throw;
        _;
    }

    modifier onlyInvestors {
        if (investorIDs[msg.sender] == 0) throw;
        _;
    }

    modifier onlyNotInvestors {
        if (investorIDs[msg.sender] != 0) throw;
        _;
    }

    modifier onlyOwner {
        if (owner != msg.sender) throw;
        _;
    }

    modifier onlyOraclize {
        if (msg.sender != oraclize_cbAddress()) throw;
        _;
    }

    modifier onlyMoreThanMinInvestment {
        if (msg.value <= getMinInvestment()) throw;
        _;
    }

    modifier onlyMoreThanZero {
        if (msg.value == 0) throw;
        _;
    }

    modifier onlyIfBetSizeIsStillCorrect(bytes32 myid) {
        Bet thisBet = bets[myid];
        if (
            (((thisBet.amountBetted * ((10000 - edge) - pwin)) / pwin) <=
                (maxWin * getBankroll()) / 10000)
        ) {
            _;
        } else {
            bets[myid].numberRolled = INVALID_BET_MARKER;
            safeSend(thisBet.playerAddress, thisBet.amountBetted);
            return;
        }
    }

    modifier onlyIfValidRoll(bytes32 myid, string result) {
        Bet thisBet = bets[myid];
        uint256 numberRolled = parseInt(result);
        if (
            (numberRolled < 1 || numberRolled > 10000) &&
            thisBet.numberRolled == 0
        ) {
            bets[myid].numberRolled = INVALID_BET_MARKER;
            safeSend(thisBet.playerAddress, thisBet.amountBetted);
            return;
        }
        _;
    }

    modifier onlyIfInvestorBalanceIsPositive(address currentInvestor) {
        if (getBalance(currentInvestor) >= 0) {
            _;
        }
    }

    modifier onlyWinningBets(uint256 numberRolled) {
        if (numberRolled - 1 < pwin) {
            _;
        }
    }

    modifier onlyLosingBets(uint256 numberRolled) {
        if (numberRolled - 1 >= pwin) {
            _;
        }
    }

    modifier onlyAfterProposed {
        if (proposedWithdrawal.toAddress == 0) throw;
        _;
    }

    modifier rejectValue {
        if (msg.value != 0) throw;
        _;
    }

    modifier onlyIfProfitNotDistributed {
        if (!profitDistributed) {
            _;
        }
    }

    modifier onlyIfValidGas(uint256 newGasLimit) {
        if (newGasLimit < 25000) throw;
        _;
    }

    modifier onlyIfNotProcessed(bytes32 myid) {
        Bet thisBet = bets[myid];
        if (thisBet.numberRolled > 0) throw;
        _;
    }

    modifier onlyIfEmergencyTimeOutHasPassed {
        if (proposedWithdrawal.atTime + EMERGENCY_TIMEOUT > now) throw;
        _;
    }

    //CONSTANT HELPER FUNCTIONS

    function getBankroll() constant returns (uint256) {
        return invested + investorsProfit - investorsLoses;
    }

    function getMinInvestment() constant returns (uint256) {
        if (numInvestors == maxInvestors) {
            uint256 investorID = searchSmallestInvestor();
            return getBalance(investors[investorID].investorAddress);
        } else {
            return 0;
        }
    }

    function getStatus()
        constant
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        uint256 bankroll = getBankroll();

        uint256 minInvestment = getMinInvestment();

        return (
            bankroll,
            pwin,
            edge,
            maxWin,
            minBet,
            amountWagered,
            (investorsProfit - investorsLoses),
            minInvestment,
            betsKeys.length
        );
    }

    function getBet(uint256 id)
        constant
        returns (
            address,
            uint256,
            uint256
        )
    {
        if (id < betsKeys.length) {
            bytes32 betKey = betsKeys[id];
            return (
                bets[betKey].playerAddress,
                bets[betKey].amountBetted,
                bets[betKey].numberRolled
            );
        }
    }

    function numBets() constant returns (uint256) {
        return betsKeys.length;
    }

    function getMinBetAmount() constant returns (uint256) {
        uint256 oraclizeFee =
            OraclizeI(OAR.getAddress()).getPrice(
                "URL",
                ORACLIZE_GAS_LIMIT + safeGas
            );
        return oraclizeFee + minBet;
    }

    function getMaxBetAmount() constant returns (uint256) {
        uint256 oraclizeFee =
            OraclizeI(OAR.getAddress()).getPrice(
                "URL",
                ORACLIZE_GAS_LIMIT + safeGas
            );
        uint256 betValue =
            ((maxWin * getBankroll()) * pwin) / (10000 * (10000 - edge - pwin));
        return betValue + oraclizeFee;
    }

    function getLosesShare(address currentInvestor) constant returns (uint256) {
        return
            (investors[investorIDs[currentInvestor]].amountInvested *
                (investorsLoses)) / invested;
    }

    function getProfitShare(address currentInvestor)
        constant
        returns (uint256)
    {
        return
            (investors[investorIDs[currentInvestor]].amountInvested *
                (investorsProfit)) / invested;
    }

    function getBalance(address currentInvestor) constant returns (uint256) {
        return
            investors[investorIDs[currentInvestor]].amountInvested +
            getProfitShare(currentInvestor) -
            getLosesShare(currentInvestor);
    }

    function searchSmallestInvestor() constant returns (uint256) {
        uint256 investorID = 1;
        for (uint256 i = 1; i <= numInvestors; i++) {
            if (
                getBalance(investors[i].investorAddress) <
                getBalance(investors[investorID].investorAddress)
            ) {
                investorID = i;
            }
        }

        return investorID;
    }

    // PRIVATE HELPERS FUNCTION

    function safeSend(address addr, uint256 value) private {
        if (this.balance < value) {
            ValueIsTooBig();
            return;
        }

        if (!(addr.call.gas(safeGas).value(value)())) {
            FailedSend(addr, value);
            if (addr != houseAddress) {
                //Forward to house address all change
                if (!(houseAddress.call.gas(safeGas).value(value)()))
                    FailedSend(houseAddress, value);
            }
        }
    }

    function addInvestorAtID(uint256 id) private {
        investorIDs[msg.sender] = id;
        investors[id].investorAddress = msg.sender;
        investors[id].amountInvested = msg.value;
        invested += msg.value;
    }

    function profitDistribution() private onlyIfProfitNotDistributed {
        uint256 copyInvested;

        for (uint256 i = 1; i <= numInvestors; i++) {
            address currentInvestor = investors[i].investorAddress;
            uint256 profitOfInvestor = getProfitShare(currentInvestor);
            uint256 losesOfInvestor = getLosesShare(currentInvestor);
            investors[i].amountInvested += profitOfInvestor - losesOfInvestor;
            copyInvested += investors[i].amountInvested;
        }

        delete investorsProfit;
        delete investorsLoses;
        invested = copyInvested;

        profitDistributed = true;
    }

    // SECTION II: BET & BET PROCESSING

    function() {
        bet();
    }

    function bet() onlyIfNotStopped onlyMoreThanZero {
        uint256 oraclizeFee =
            OraclizeI(OAR.getAddress()).getPrice(
                "URL",
                ORACLIZE_GAS_LIMIT + safeGas
            );
        uint256 betValue = msg.value - oraclizeFee;
        if (
            (((betValue * ((10000 - edge) - pwin)) / pwin) <=
                (maxWin * getBankroll()) / 10000) && (betValue >= minBet)
        ) {
            // encrypted arg: '\n{"jsonrpc":2.0,"method":"generateSignedIntegers","params":{"apiKey":"YOUR_API_KEY","n":1,"min":1,"max":10000},"id":1}'
            bytes32 myid =
                oraclize_query(
                    "URL",
                    "json(https://api.random.org/json-rpc/1/invoke).result.random.data.0",
                    "BBX1PCQ9134839wTz10OWxXCaZaGk92yF6TES8xA+8IC7xNBlJq5AL0uW3rev7IoApA5DMFmCfKGikjnNbNglKKvwjENYPB8TBJN9tDgdcYNxdWnsYARKMqmjrJKYbBAiws+UU6HrJXUWirO+dBSSJbmjIg+9vmBjSq8KveiBzSGmuQhu7/hSg5rSsSP/r+MhR/Q5ECrOHi+CkP/qdSUTA/QhCCjdzFu+7t3Hs7NU34a+l7JdvDlvD8hoNxyKooMDYNbUA8/eFmPv2d538FN6KJQp+RKr4w4VtAMHdejrLM=",
                    ORACLIZE_GAS_LIMIT + safeGas
                );
            bets[myid] = Bet(msg.sender, betValue, 0);
            betsKeys.push(myid);
        } else {
            throw;
        }
    }

    function __callback(
        bytes32 myid,
        string result,
        bytes proof
    )
        onlyOraclize
        onlyIfNotProcessed(myid)
        onlyIfValidRoll(myid, result)
        onlyIfBetSizeIsStillCorrect(myid)
    {
        Bet thisBet = bets[myid];
        uint256 numberRolled = parseInt(result);
        bets[myid].numberRolled = numberRolled;
        isWinningBet(thisBet, numberRolled);
        isLosingBet(thisBet, numberRolled);
        amountWagered += thisBet.amountBetted;
        delete profitDistributed;
    }

    function isWinningBet(Bet thisBet, uint256 numberRolled)
        private
        onlyWinningBets(numberRolled)
    {
        uint256 winAmount = (thisBet.amountBetted * (10000 - edge)) / pwin;
        BetWon(thisBet.playerAddress, numberRolled, winAmount);
        safeSend(thisBet.playerAddress, winAmount);
        investorsLoses += (winAmount - thisBet.amountBetted);
    }

    function isLosingBet(Bet thisBet, uint256 numberRolled)
        private
        onlyLosingBets(numberRolled)
    {
        BetLost(thisBet.playerAddress, numberRolled);
        safeSend(thisBet.playerAddress, 1);
        investorsProfit +=
            ((thisBet.amountBetted - 1) * (10000 - houseEdge)) /
            10000;
        uint256 houseProfit =
            ((thisBet.amountBetted - 1) * (houseEdge)) / 10000;
        safeSend(houseAddress, houseProfit);
    }

    //SECTION III: INVEST & DIVEST

    function increaseInvestment()
        onlyIfNotStopped
        onlyMoreThanZero
        onlyInvestors
    {
        profitDistribution();
        investors[investorIDs[msg.sender]].amountInvested += msg.value;
        invested += msg.value;
    }

    function newInvestor()
        payable
        onlyIfNotStopped
        onlyMoreThanZero
        onlyNotInvestors
        onlyMoreThanMinInvestment
    {
        profitDistribution();

        if (numInvestors == maxInvestors) {
            uint256 smallestInvestorID = searchSmallestInvestor();
            divest(investors[smallestInvestorID].investorAddress);
        }

        numInvestors++;
        addInvestorAtID(numInvestors);
    }

    function divest() onlyInvestors rejectValue {
        divest(msg.sender);
    }

    function divest(address currentInvestor)
        private
        onlyIfInvestorBalanceIsPositive(currentInvestor)
    {
        profitDistribution();
        uint256 currentID = investorIDs[currentInvestor];
        uint256 amountToReturn = getBalance(currentInvestor);
        invested -= investors[currentID].amountInvested;
        uint256 divestFeeAmount = (amountToReturn * divestFee) / 10000;
        amountToReturn -= divestFeeAmount;

        delete investors[currentID];
        delete investorIDs[currentInvestor];
        //Reorder investors

        if (currentID != numInvestors) {
            // Get last investor
            Investor lastInvestor = investors[numInvestors];
            //Set last investor ID to investorID of divesting account
            investorIDs[lastInvestor.investorAddress] = currentID;
            //Copy investor at the new position in the mapping
            investors[currentID] = lastInvestor;
            //Delete old position in the mappping
            delete investors[numInvestors];
        }

        numInvestors--;
        safeSend(currentInvestor, amountToReturn);
        safeSend(houseAddress, divestFeeAmount);
    }

    function forceDivestOfAllInvestors() onlyOwner rejectValue {
        uint256 copyNumInvestors = numInvestors;
        for (uint256 i = 1; i <= copyNumInvestors; i++) {
            divest(investors[1].investorAddress);
        }
    }

    /*
    The owner can use this function to force the exit of an investor from the
    contract during an emergency withdrawal in the following situations:
        - Unresponsive investor
        - Investor demanding to be paid in other to vote, the facto-blackmailing
        other investors
    */
    function forceDivestOfOneInvestor(address currentInvestor)
        onlyOwner
        onlyIfStopped
        rejectValue
    {
        divest(currentInvestor);
        //Resets emergency withdrawal proposal. Investors must vote again
        delete proposedWithdrawal;
    }

    //SECTION IV: CONTRACT MANAGEMENT

    function stopContract() onlyOwner rejectValue {
        isStopped = true;
    }

    function resumeContract() onlyOwner rejectValue {
        isStopped = false;
    }

    function changeHouseAddress(address newHouse) onlyOwner rejectValue {
        houseAddress = newHouse;
    }

    function changeOwnerAddress(address newOwner) onlyOwner rejectValue {
        owner = newOwner;
    }

    function changeGasLimitOfSafeSend(uint256 newGasLimit)
        onlyOwner
        onlyIfValidGas(newGasLimit)
        rejectValue
    {
        safeGas = newGasLimit;
    }

    //SECTION V: EMERGENCY WITHDRAWAL

    function voteEmergencyWithdrawal(bool vote)
        onlyInvestors
        onlyAfterProposed
        onlyIfStopped
        rejectValue
    {
        investors[investorIDs[msg.sender]].votedForEmergencyWithdrawal = vote;
    }

    function proposeEmergencyWithdrawal(address withdrawalAddress)
        onlyIfStopped
        onlyOwner
        rejectValue
    {
        //Resets previous votes
        for (uint256 i = 1; i <= numInvestors; i++) {
            delete investors[i].votedForEmergencyWithdrawal;
        }

        proposedWithdrawal = WithdrawalProposal(withdrawalAddress, now);
        EmergencyWithdrawalProposed();
    }

    function executeEmergencyWithdrawal()
        onlyOwner
        onlyAfterProposed
        onlyIfStopped
        onlyIfEmergencyTimeOutHasPassed
        rejectValue
    {
        uint256 numOfVotesInFavour;
        uint256 amountToWithdrawal = this.balance;

        for (uint256 i = 1; i <= numInvestors; i++) {
            if (investors[i].votedForEmergencyWithdrawal == true) {
                numOfVotesInFavour++;
                delete investors[i].votedForEmergencyWithdrawal;
            }
        }

        if (
            numOfVotesInFavour >=
            (emergencyWithdrawalRatio * numInvestors) / 100
        ) {
            if (!proposedWithdrawal.toAddress.send(this.balance)) {
                EmergencyWithdrawalFailed(proposedWithdrawal.toAddress);
            } else {
                EmergencyWithdrawalSucceeded(
                    proposedWithdrawal.toAddress,
                    amountToWithdrawal
                );
            }
        } else {
            throw;
        }
    }
}
