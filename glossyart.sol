pragma solidity ^0.4.23;


//
// Helper Contracts
//

/**
 * @title Ownable
 * @dev The Ownable contract has an owner address, and provides basic authorization control
 * functions, this simplifies the implementation of "user permissions".
 * By OpenZeppelin. MIT License. https://github.com/OpenZeppelin/zeppelin-solidity
 * This method has been modified by Glossy for two-step transfers since a mistake would be fatal.
 */
contract Ownable {
  address public owner;
  address public pendingOwner;

  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);


  /**
   * @dev The Ownable constructor sets the original `owner` of the contract to the sender
   * account.
   */
  constructor() public {
    owner = msg.sender;
    pendingOwner = msg.sender;
  }

  /**
   * @dev Throws if called by any account other than the owner.
   */
  modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }

  /**
   * @dev Approve transfer as step one prior to transfer
   * @param newOwner The address to transfer ownership to.
   */
  function approveOwnership(address newOwner) public onlyOwner {
    require(newOwner != address(0));
    pendingOwner = newOwner;
  }
  /**
   * @dev Allows the pending owner to transfer control of the contract.
   */
  function transferOwnership() public {
    require(msg.sender == pendingOwner);
    emit OwnershipTransferred(owner, pendingOwner);
    owner = pendingOwner;
  }

}
/**
 * @title Pausable
 * @dev Base contract which allows children to implement an emergency stop mechanism.
 * By OpenZeppelin. MIT License. https://github.com/OpenZeppelin/zeppelin-solidity
 */
contract Pausable is Ownable {
  event Pause();
  event Unpause();

  bool public paused = false;


  /**
   * @dev Modifier to make a function callable only when the contract is not paused.
   */
  modifier whenNotPaused() {
    require(!paused);
    _;
  }

  /**
   * @dev Modifier to make a function callable only when the contract is paused.
   */
  modifier whenPaused() {
    require(paused);
    _;
  }

  /**
   * @dev called by the owner to pause, triggers stopped state
   */
  function pause() onlyOwner whenNotPaused public {
    paused = true;
    emit Pause();
  }

  /**
   * @dev called by the owner to unpause, returns to normal state
   */
  function unpause() onlyOwner whenPaused public {
    paused = false;
    emit Unpause();
  }
}

/** @title TXGuard
 *  @dev The purpose of this contract is to determine transfer fees to be sent to creators
 **/
interface TXGuard {
  function getTxAmount(uint256 _tokenId) external pure returns (uint256);
  function getOwnerPercent(address _owner) external view returns (uint256);
}

/** @title ERC721MetadataExt
 *  @dev Metadata (externally) for the contract
 **/
interface ERC721MetadataExt {
    function getTokenURI(uint256 _tokenId) external pure returns (bytes32[4] buffer, uint16 count);
    function tokenOfOwnerByIndex(address _owner, uint256 _index) external view returns (uint256 _tokenId);
}

/** @title ERC721ERC721TokenReceiver
 **/
interface ERC721TokenReceiver {
  function onERC721Received(address _from, uint256 _tokenId, bytes data) external returns(bytes4);
}

/// @title Interface for contracts conforming to ERC-721: Non-Fungible Tokens
/// @author Dieter Shirley <dete@axiomzen.co> (https://github.com/dete)
contract ERC721 {
    // Required methods
    function totalSupply() public view returns (uint256 total);
    function balanceOf(address _owner) external view returns (uint256 balance);
    function ownerOf(uint256 _tokenId) public view returns (address owner);
    function approve(address _to, uint256 _tokenId) external payable;
    function transfer(address _to, uint256 _tokenId) external payable;
    function transferFrom(address _from, address _to, uint256 _tokenId) external payable;

    // Events
    event Transfer(address indexed _from, address indexed _to, uint256 _tokenId);
    // New Card is to ensure there is a record of card purchase in case an error occurs
    event NewCard(address indexed _from, uint256 _cardId);
    event Approval(address indexed _owner, address indexed _approved, uint256 _tokenId);
    event ApprovalForAll(address indexed _owner, address indexed _operator, bool _approved);
    event ContractUpgrade(address _newContract);
    // Not in the standard, but using "Birth" to be consistent with announcing newly issued cards
    event Birth(uint256 _newCardIndex, address _creator, string _metadata, uint256 _price, uint16 _max);

    // Optional
    // function name() public view returns (string name);
    // function symbol() public view returns (string symbol);
    // function tokensOfOwner(address _owner) external view returns (uint256[] tokenIds);
    // function tokenMetadata(uint256 _tokenId, string _preferredTransport) public view returns (string infoUrl);

    // ERC-165 Compatibility (https://github.com/ethereum/EIPs/issues/165)
    function supportsInterface(bytes4 _interfaceID) external view returns (bool);
}

/** @title Glossy
 *  @dev This is the main Glossy contract
 **/
contract Glossy is Pausable, ERC721 {

  bytes4 constant InterfaceSignature_ERC165 =
      bytes4(keccak256('supportsInterface(bytes4)'));

  // From CryptoKitties. This is supported as well as the new 721 defs
  bytes4 constant InterfaceSignature_ERC721 =
      bytes4(keccak256('name()')) ^
      bytes4(keccak256('symbol()')) ^
      bytes4(keccak256('totalSupply()')) ^
      bytes4(keccak256('balanceOf(address)')) ^
      bytes4(keccak256('ownerOf(uint256)')) ^
      bytes4(keccak256('approve(address,uint256)')) ^
      bytes4(keccak256('transfer(address,uint256)')) ^
      bytes4(keccak256('transferFrom(address,address,uint256)')) ^
      bytes4(keccak256('tokensOfOwner(address)')) ^
      bytes4(keccak256('tokenMetadata(uint256,string)'));

  bytes4 private constant ERC721_RECEIVED = 0xf0b9e5ba;

  /** @dev ERC165 implemented. This implements the original ERC721 interface
   *  as well as the "official" interface.
   *  @param _interfaceID the combined keccak256 hash of the interface methods
   **/
  function supportsInterface(bytes4 _interfaceID) external view returns (bool)
  {
      return (_interfaceID == InterfaceSignature_ERC165 ||
              _interfaceID == InterfaceSignature_ERC721 ||
              _interfaceID == 0x80ac58cd ||
              _interfaceID == 0x5b5e139f ||
              _interfaceID == 0x780e9d63
              );
  }

  uint256 public minimumPrice;
  uint256 public globalCut;

  address public pendingMaster;
  address public masterAddress;
  address public workerAddress;

  string public metadataURL;

  address public newContract;
  address public txGuard;
  address public erc721Metadata;

  /* ERC20 Compatibility */
  string public constant name = "Glossy";
  string public constant symbol = "GLSY";

  mapping (uint256 => address) public tokenIndexToOwner;

  mapping (address => uint256) public ownershipTokenCount;

  mapping (uint256 => address) public tokenIndexToApproved;

  mapping (address => mapping (address => bool)) public operatorApprovals;

  modifier canOperate(uint256 _tokenId) {
    address owner = tokenIndexToOwner[_tokenId];
    require(msg.sender == owner || operatorApprovals[owner][msg.sender]);
    _;
  }

  modifier canTransfer(uint256 _tokenId) {
    address owner = tokenIndexToOwner[_tokenId];
    require(msg.sender == owner ||
           msg.sender == tokenIndexToApproved[_tokenId] ||
           operatorApprovals[owner][msg.sender]);
    _;
  }

  modifier onlyMaster() {
    require(msg.sender == masterAddress);
    _;
  }

  modifier onlyWorker() {
    require(msg.sender == workerAddress);
    _;
  }


  //
  // Setting addresses for control and contract helpers
  //

  /** @dev Set the master address responsible for function level contract control
   *  @param _newMaster New Address for master
   **/
  function setMaster(address _newMaster) external onlyMaster {
      require(_newMaster != address(0));

      pendingMaster = _newMaster;
  }

  /** @dev Accept master address
   **/
  function acceptMaster() external {
      require(pendingMaster != address(0));
      require(pendingMaster == msg.sender);

      masterAddress = pendingMaster;
  }

  /** @dev Set the worker address responsible for card creation
   *  @param _newWorker New Worker for card creation
   **/
  function setWorker(address _newWorker) external onlyMaster {
      require(_newWorker != address(0));

      workerAddress = _newWorker;
  }

  /** @dev Set new contract address, emits a ContractUpgrade
   *  @param _newContract The address of the new contract
   **/
  function setContract(address _newContract) external onlyOwner {
      require(_newContract != address(0));
      emit ContractUpgrade(_newContract);
      newContract = _newContract;
  }

  /** @dev Set contract for txGuard, a contract used to recover funds on transfers
   *  @param _txGuard address for txGuard
   **/
  function setTxGuard(address _txGuard) external onlyMaster {
      require(_txGuard != address(0));
      txGuard = _txGuard;
  }

  /** @dev Set ERC721Metadata contract
   *  @param _erc721Metadata is the contract address
   **/
  function setErc721Metadata(address _erc721Metadata) external onlyMaster {
      require(_erc721Metadata != address(0));
      erc721Metadata = _erc721Metadata;
  }

  /* This structure attempts to minimize data stored in contract.
     On average, assuming 10 cards, it would use 128 bits which is
     reasonable in terms of storage. CK uses 512 bits per token.
     Baseline 512 bits
     Single 1024 bits
     Average (1024 + 256) / 10 = 128 bits
  */
  struct Card {
      uint16  count;    // 16
      uint16  max;      // 16
      uint256 price;    // 256
      address creator;  // 160
      string  dataHash; // 256
      string  metadata; // 320
  }

  // Structure done this way for readability
  struct Token {
    uint256 card;
  }

  Card[] cards;
  Token[] tokens;

  constructor(address _workerAddress, uint256 _minimumPrice, uint256 _globalCut, string _metadataURL) public {

    masterAddress = msg.sender;
    workerAddress = _workerAddress;
    minimumPrice = _minimumPrice;
    globalCut = _globalCut;
    metadataURL = _metadataURL;

    // Create a card 0, necessary as a placeholder for new card creation
    _newCard(0,0,0,address(0),"","");

  }

  //
  // Enumerated
  //

  /** @dev Total supply of Glossy cards
   **/
  function totalSupply() public view returns (uint256 _totalTokens) {
    return tokens.length;
  }

  /** @dev A token identifier for the given index
   *  @param _index the index of the token
   **/
  function tokenByIndex(uint256 _index) external pure returns (uint256) {
    return _index + 1;
  }

  //
  //
  //

  /** @dev Balance for a particular address.
   *  @param _owner The owner of the returned balance
   **/
  function balanceOf(address _owner) external view returns (uint256 _balance) {
    return ownershipTokenCount[_owner];
  }

  /**** ERC721 ****/

  function _newCard(uint16 _count, uint16 _max, uint256 _price, address _creator, string _dataHash, string _metadata) internal returns (uint256 newCardIndex){
    Card memory card = Card({
      count:_count,
      max:_max,
      price:_price,
      creator:_creator,
      dataHash:_dataHash,
      metadata:_metadata
    });
    newCardIndex = cards.push(card) - 1;
    emit Birth(newCardIndex, _creator, _metadata, _price, _max);
  }

  // Worker will populate a card and assign it to the token
  function populateNew(uint16 _max, uint256 _price, address _creator, string _dataHash, string _metadata, uint256 _tokenId) external onlyWorker {

    uint16 count = (_tokenId == 0 ? 0 : 1);
    uint256 newCardIndex = _newCard(count, _max, _price, _creator, _dataHash, _metadata);

    // If we are creating a new series entirely programmatically
    if(_tokenId == 0) {
      return;
    }
    // Make sure the token at the index isn't already populated.
    require(tokens[_tokenId].card == 0);
    // Set the card to the newly added card index
    tokens[_tokenId].card = newCardIndex;
    // We have to transfer at this point rather than purchaseNew
    uint256 cutAmount = _getCut(uint128(_price), _creator);
    uint256 amount = _price - cutAmount;
    _creator.transfer(amount);
  }

  // Hopefully never needed.
  function correctNew(uint256 _cardId, uint256 _tokenId) external onlyWorker {
      // Make sure the token at the index isn't already populated.
      require(tokens[_tokenId].card == 0);
      // Set the card to the newly added card index
      tokens[_tokenId].card = _cardId;
  }

  // Purchase hot off the press
  // Accept funds and let backend authorize the rest
  function purchaseNew(uint256 _cardId) external payable whenNotPaused returns (uint256 tokenId) {

    // Must be minimum purchase price to prevent empty tokens being bought for ~0
    require(msg.value >= minimumPrice);
    //
    // Transfer the token, step 1 of a two step process.
    tokenId = tokens.push(Token({card:0})) - 1;
    tokenIndexToOwner[tokenId] = msg.sender;
    ownershipTokenCount[msg.sender]++;

    emit NewCard(msg.sender, _cardId);
    emit Transfer(address(0), msg.sender, tokenId);
  }

  // Standard purchase, website is responsible for calling this OR purchaseNew
  function purchase(uint256 _cardId) public payable whenNotPaused {

      Card storage card = cards[_cardId];
      address creator = card.creator;

      require(card.count < card.max);
      require(msg.value == card.price);

      card.count++;

      uint256 tokenId = tokens.push(Token({card:_cardId})) - 1;

      tokenIndexToOwner[tokenId] = msg.sender;
      ownershipTokenCount[msg.sender]++;

      emit Transfer(address(0), msg.sender, tokenId);

      uint256 amount = msg.value - _getCut(uint128(msg.value), creator);
      creator.transfer(amount);
  }

  /* Internal transfer method */
  function _transfer(address _from, address _to, uint256 _tokenId) internal {

    // Update ownership counts
    ownershipTokenCount[_from]--;
    ownershipTokenCount[_to]++;

    // Transfer ownership
    tokenIndexToOwner[_tokenId] = _to;

    // Emit transfer event
    emit Transfer(_from, _to, _tokenId);

  }

  /** @dev Transfer asset to a particular address.
   *  @param _to Address receiving the asset
   *  @param _tokenId ID of asset
   **/
  function transfer(address _to, uint256 _tokenId) external payable whenNotPaused {
    require(_to != address(0));
    require(_to != address(this));
    require(msg.sender == ownerOf(_tokenId));
    // txGuard is a mechanism that allows a percentage of the transaction to be accepted to benefit asset holders
    if(txGuard != address(0)) {
      require(TXGuard(txGuard).getTxAmount(_tokenId) == msg.value);
      transferCut(msg.value, _tokenId);
    }
    _transfer(msg.sender, _to, _tokenId);
  }

  /** @dev Transfer asset to a particular address by worker
   *  @param _to Address receiving the asset
   *  @param _tokenId ID of asset
   **/
  function transferByWorker(address _to, uint256 _tokenId) external onlyWorker {
    require(_to != address(0));
    require(_to != address(this));

    _transfer(msg.sender, _to, _tokenId);
  }

  /* Two step transfer to ensure ownership */
  function approve(address _approved, uint256 _tokenId) external payable canOperate(_tokenId) {
     address _owner = tokenIndexToOwner[_tokenId];
     if (_owner == address(0)) {
         _owner = address(this);
     }
     tokenIndexToApproved[_tokenId] = _approved;
     emit Approval(_owner, _approved, _tokenId);
   }

  function setApprovalForAll(address _operator, bool _approved) external {
    operatorApprovals[msg.sender][_operator] = _approved;
    emit ApprovalForAll(msg.sender, _operator, _approved);
  }

  function getApproved(uint256 _tokenId) external view returns (address) {
    return tokenIndexToApproved[_tokenId];
  }

  function isApprovedForAll(address _owner, address _operator) external view returns (bool) {
    return operatorApprovals[_owner][_operator];
  }

  function transferFrom(address _from, address _to, uint256 _tokenId) payable whenNotPaused external {
    require(_to != address(0));
    require(_to != address(this));
    require(tokenIndexToApproved[_tokenId] == msg.sender);
    require(_from == ownerOf(_tokenId));
    // txGuard is a mechanism that allows a percentage of the transaction to be accepted to benefit asset holders
    if(txGuard != address(0)) {
      require(TXGuard(txGuard).getTxAmount(_tokenId) == msg.value);
      transferCut(msg.value, _tokenId);
    }
    _transfer(_from, _to, _tokenId);

  }

  function safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes data) external payable whenNotPaused {
    _safeTransferFrom(_from, _to, _tokenId, data);
  }

  function safeTransferFrom(address _from, address _to, uint256 _tokenId) external payable whenNotPaused {
    _safeTransferFrom(_from, _to, _tokenId, "");
  }

  function _safeTransferFrom(address _from, address _to, uint256 _tokenId, bytes data) private canTransfer(_tokenId) {
    address owner = tokenIndexToOwner[_tokenId];

    if (owner == address(0)) {
        owner = address(this);
    }
    require(owner == _from);
    require(_to != address(0));
    if(txGuard != address(0)) {
      require(TXGuard(txGuard).getTxAmount(_tokenId) == msg.value);
      transferCut(msg.value, _tokenId);
    }
    _transfer(_from, _to, _tokenId);

    uint256 codeSize;
    assembly { codeSize := extcodesize(_to) }
    if(codeSize == 0) {
      return;
    }

    bytes4 retval = ERC721TokenReceiver(_to).onERC721Received(_from, _tokenId, data);
    require(retval == ERC721_RECEIVED);
  }



  /** @dev Take a token and attempt to transfer copies to multiple addresses.
   *       This can only be executed by a worker.
   *  @param _to Addresses receiving the asset.
   *  @param _cardId The card for which tokens should be assigned
   **/
  function multiTransfer(address[] _to, uint256 _cardId) external onlyWorker {
    Card storage _card = cards[_cardId];
    require(_card.count + _to.length <= _card.max);

    _card.count = _card.count + uint8(_to.length);

    for(uint16 i = 0; i < _to.length; i++) {

      uint256 tokenId = tokens.push(Token({card:_cardId})) - 1;
      address newOwner = _to[i];
      tokenIndexToOwner[tokenId] = newOwner;
      ownershipTokenCount[newOwner]++;

      emit Transfer(address(0), newOwner, tokenId);
    }
  }

  /** @dev Returns the owner of the token index given.
   *  @param _tokenId The token index whose owner is queried.
   **/
  function ownerOf(uint256 _tokenId) public view returns (address owner) {
    owner = tokenIndexToOwner[_tokenId];
  }

  function tokenOfOwnerByIndex(address _owner, uint256 _index) external view returns (uint256 _tokenId) {
    require(erc721Metadata != address(0));

    _tokenId = ERC721MetadataExt(erc721Metadata).tokenOfOwnerByIndex(_owner, _index);
  }

  function tokensOfOwner(address _owner) external view returns (uint256[] tokenIds) {
    require(erc721Metadata != address(0));

    uint256 bal = this.balanceOf(_owner);
    uint256[] memory _tokenIds = new uint256[](bal);
    uint256 _index = 0;
    for(; _index < bal; _index++) {
      _tokenIds[_index] = this.tokenOfOwnerByIndex(_owner, _index);
    }
    return _tokenIds;
  }

  /** @dev This returns the metadata for the given token.
   *  tokenURI points to another contract, by default at address 0.
   *  Metadata is still being debated, and the current implementation requires
   *  some verbose JSON which seems against the spirit of data efficiency. The
   *  ERC721 tokenMetadata method is implemented for compatibility.
   *  @param _tokenId The token index for which the metadata should be returned.
   **/
  function tokenURI(uint256 _tokenId) external view returns (string infoUrl) {
      require(erc721Metadata != address(0));
      // URL for metadata
      bytes32[4] memory buffer;
      uint256 count;
      (buffer, count) = ERC721MetadataExt(erc721Metadata).getTokenURI(_tokenId);

      return _toString(buffer, count);
  }

  /** @dev This returns the metadata for the given token.
   *  This is currently supported while tokenURI is not.
   *  @param _tokenId The token index for which the metadata should be returned.
   *  @param _preferredTransport The protocol (https, ipfs) of the metadata source.
   **/
  function tokenMetadata(uint256 _tokenId, string _preferredTransport) external view returns (string metadata) {
    Token storage _token = tokens[_tokenId];
    Card storage _card = cards[_token.card];
    if(keccak256(_preferredTransport) == keccak256("http")) {
      return _concat(metadataURL, _card.metadata);
    }
    return _card.metadata;
  }

  /** @dev Set the metadata URL
   *  @param _metadataURL New URL
   **/
  function setMetadataURL(string _metadataURL) external onlyMaster {
    metadataURL = _metadataURL;
  }

  function setMinimumPrice(uint256 _minimumPrice) external onlyMaster {
    minimumPrice = _minimumPrice;
  }

  function setCreatorAddress(address _newAddress, uint256 _cardId) external whenNotPaused {
      Card storage card = cards[_cardId];
      address creator = card.creator;
      require(_newAddress != address(0));
      require(msg.sender == creator);

      card.creator = _newAddress;
}

  /** @dev This is a withdrawl method, though it isn't intended to be used often or for much.
   *  @param _amount Amount to be moved
   **/
  function withdrawAmount(uint256 _amount) external onlyMaster {
    uint256 balance = address(this).balance;
    require(_amount <= balance);
    masterAddress.transfer(_amount);
  }

  /** @dev This returns the amount required to send the contract for a transfer.
   *  @param _tokenId The token index to be checked
   **/
  function getTxAmount(uint256 _tokenId) external view returns (uint256 _amount) {
    if(txGuard == address(0))
      return 0;
    return TXGuard(txGuard).getTxAmount(_tokenId);
  }
  /** @dev Transfer a fixed cut to the asset owner
   *  @param _cutAmount amount of cut
   **/
   function transferCut(uint256 _cutAmount, uint256 _tokenId) internal {
     Token storage _token = tokens[_tokenId];
     Card storage _card = cards[_token.card];
     address creatorAddress = _card.creator;

     uint256 creatorAmount = _cutAmount - _getCut(uint128(_cutAmount * 15), creatorAddress);

     creatorAddress.transfer(creatorAmount);
   }
  /** @dev Set the global cut
   *  @param _cut percentage of asset transaction
   **/
  function setGlobalCut(uint256 _cut) external onlyMaster {
    globalCut = _cut;
  }

  /** @dev Get the cut for contract operations
   *  @param _amount Total price of item
   **/
  function _getCut(uint128 _amount, address _creator) internal view returns (uint256) {
    if(txGuard != address(0)) {
      return _amount * TXGuard(txGuard).getOwnerPercent(_creator) / 10000;
    }
    return _amount * globalCut / 10000;
  }

  // Helper Functions

  /** @dev Via CryptoKitties: Adapted from memcpy() by @arachnid (Nick Johnson <arachnid@notdot.net>)
   *  This method is licenced under the Apache License.
   *  Ref: https://github.com/Arachnid/solidity-stringutils/blob/2f6ca9accb48ae14c66f1437ec50ed19a0616f78/strings.sol
   **/
  function _memcpy(uint _dest, uint _src, uint _len) private pure {
      // Copy word-length chunks while possible
      for(; _len >= 32; _len -= 32) {
          assembly {
              mstore(_dest, mload(_src))
          }
          _dest += 32;
          _src += 32;
      }

      // Copy remaining bytes
      uint256 mask = 256 ** (32 - _len) - 1;
      assembly {
          let srcpart := and(mload(_src), not(mask))
          let destpart := and(mload(_dest), mask)
          mstore(_dest, or(destpart, srcpart))
      }
  }
  /** @dev Via CryptoKitties: Adapted from toString(slice) by @arachnid (Nick Johnson <arachnid@notdot.net>)
   *  This method is licenced under the Apache License.
   *  Ref: https://github.com/Arachnid/solidity-stringutils/blob/2f6ca9accb48ae14c66f1437ec50ed19a0616f78/strings.sol
   **/
  function _toString(bytes32[4] _rawBytes, uint256 _stringLength) internal pure returns (string outputString) {
      outputString = new string(_stringLength);
      uint256 outputPtr;
      uint256 bytesPtr;

      assembly {
          outputPtr := add(outputString, 32)
          bytesPtr := _rawBytes
      }

      _memcpy(outputPtr, bytesPtr, _stringLength);

  }
  /** @dev This method takes two strings, concatenates the bytes, and then returns a string.
   *  @param _first First string
   *  @param _second Second string
   **/
  function _concat(string _first, string _second) internal pure returns (string _result){

    bytes memory __first = bytes(_first);
    bytes memory __second = bytes(_second);

    _result = new string(__first.length + __second.length);

    bytes memory __result = bytes(_result);

    uint ptr = 0;
    uint i = 0;
    for (; i < __first.length; i++)
      __result[ptr++] = __first[i];
    for (i = 0; i < __second.length; i++)
      __result[ptr++] = __second[i];

    _result = string(__result);
  }

}
