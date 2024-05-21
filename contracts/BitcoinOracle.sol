// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.13;

import "./Endian.sol";
import "./BytesLib.sol";

contract BitcoinOracle {
    struct Header {
        // The following are fields specified in the Bitcoin block header.
        bytes32 prevBlock;
        bytes32 merkleRoot;
        int32 version;
        uint32 timestamp;
        uint32 bits;
        uint32 nonce;
        uint64 height;
        // Whether this block is on the canonical chain. Being on the canonical chain means it is part of the chain with the greatest amount of work recognized by the consensus.
        bool isCanonical;
        // The total amount of work since the initial block submitted at the creation of the contract, including the initial block. For blocks before the initial block, it can be negative.
        int256 chainWorkSinceInitBlock;
    }

    // This variable is intentionally designed to be private, because we do not want users to directly use the block height to obtain blocks that do not have a sufficient number of confirmations. Users should use getBlockHashByHeight instead.
    // Mapping from block heights to block hashes on canonical chain. May change due to reorg.
    mapping(uint256 => bytes32) internal heightToHash;

    // Mapping from block hashes to block headers, including blocks on non-canonical chains.
    mapping(bytes32 => Header) internal blockHeaders;

    // The latest block hash of the canonical chain. This is the block with the most work we know of.
    bytes32 public latestBlockHash;

    // The first block hash of the canonical chain submitted to this contract.
    bytes32 public firstBlockHash;

    // Some constants related to consensus.
    uint32 public constant powTargetTimespan = 1209600;
    uint256 public constant difficultyAdjustmentInterval = 2016;
    uint256 public constant powLimit = 0x00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    uint256 public constant minConfirmations = 6;

    // This is used to disable PoW check for testing purpose. Must be true in a production deployment.
    bool public immutable checkPoW;

    // The initial block height submitted when this contract is created, forking below this height is not permitted.
    uint256 public immutable initBlockHeight;

    event NewBlockHeader(bytes32 indexed blockHash, uint256 indexed blockHeight, bytes header, bool latestUpdated);

    constructor(uint256 _initBlockHeight, bytes memory _initHeader, bool _checkPoW) {
        // This check is to ensure that the next difficulty adjustment can be calculated correctly, as the difficulty adjustment relies on the timestamp from the block before the past 2016 blocks.
        require(
            _initBlockHeight % difficultyAdjustmentInterval == 0,
            "initBlockHeight must be the first block of a 2016 blocks period"
        );

        (
            int32 version,
            bytes32 blockHash,
            bytes32 prevBlock,
            bytes32 merkleRoot,
            uint32 timestamp,
            uint32 bits,
            uint32 nonce
        ) = parseHeader(_initHeader);

        blockHeaders[blockHash] = Header({
            prevBlock: prevBlock,
            merkleRoot: merkleRoot,
            version: version,
            timestamp: timestamp,
            bits: bits,
            nonce: nonce,
            height: uint64(_initBlockHeight),
            isCanonical: true,
            chainWorkSinceInitBlock: bitsToWork(bits)
        });
        latestBlockHash = blockHash;
        heightToHash[_initBlockHeight] = blockHash;
        firstBlockHash = blockHash;

        // This is only for testing.
        checkPoW = _checkPoW;

        initBlockHeight = _initBlockHeight;

        emit NewBlockHeader(blockHash, _initBlockHeight, _initHeader, true);
    }

    /// @notice batch submit new block headers
    function batchSubmitHeader(bytes[] calldata headers) external {
        for (uint256 i = 0; i < headers.length; i++) {
            submitHeader(headers[i]);
        }
    }

    /// @notice submit new block header
    function submitHeader(bytes calldata header) public {
        require(header.length == 80, "Invalid header length");

        bytes32 blockHash;
        uint256 newHeight;
        bytes32 prevBlock;
        int256 newChainWork;

        // avoid stack too deep error
        {
            int32 version;
            bytes32 merkleRoot;
            uint32 timestamp;
            uint32 bits;
            uint32 nonce;
            (version, blockHash, prevBlock, merkleRoot, timestamp, bits, nonce) = parseHeader(header);

            require(blockHeaders[blockHash].merkleRoot == bytes32(0), "Header already exists");

            Header storage prevHeader = blockHeaders[prevBlock];
            // prev block does not exist
            if (prevHeader.merkleRoot == bytes32(0)) {
                // submit the block before first block
                Header storage firstHeader = blockHeaders[firstBlockHash];
                if (blockHash == firstHeader.prevBlock) {
                    // We don't need to verify the block's validity because firstBlockHash already includes the commitment of previous blocks
                    newHeight = firstHeader.height - 1;
                    blockHeaders[blockHash] = Header({
                        prevBlock: prevBlock,
                        merkleRoot: merkleRoot,
                        version: version,
                        timestamp: timestamp,
                        bits: bits,
                        nonce: nonce,
                        height: uint64(newHeight),
                        isCanonical: true,
                        chainWorkSinceInitBlock: firstHeader.chainWorkSinceInitBlock - bitsToWork(firstHeader.bits)
                    });
                    firstBlockHash = blockHash;
                    heightToHash[newHeight] = blockHash;
                    emit NewBlockHeader(blockHash, newHeight, header, false);
                    return;
                }
                revert("Prev block not found");
            }

            newHeight = prevHeader.height + 1;
            require(newHeight > initBlockHeight, "Forks before initBlockHeight are not accepted");
            uint256 target = bitsToTarget(bits);
            if (checkPoW) {
                require(nextBlockBits(prevHeader, newHeight) == bits, "Invalid bits");
                require(uint256(blockHash) <= target, "Invalid PoW");
            }

            newChainWork = prevHeader.chainWorkSinceInitBlock + targetToWork(target);

            blockHeaders[blockHash] = Header({
                prevBlock: prevBlock,
                merkleRoot: merkleRoot,
                version: version,
                timestamp: timestamp,
                bits: bits,
                nonce: nonce,
                height: uint64(newHeight),
                isCanonical: true,
                chainWorkSinceInitBlock: newChainWork
            });
        }

        bool latestUpdated = false;
        bytes32 _latestBlockHash = latestBlockHash;
        // This can save gas in most cases
        if (_latestBlockHash == prevBlock) {
            latestUpdated = true;
            heightToHash[newHeight] = blockHash;
            latestBlockHash = blockHash;
        } else {
            if (newChainWork > blockHeaders[_latestBlockHash].chainWorkSinceInitBlock) {
                latestUpdated = true;
                bytes32 currBlockHash = prevBlock;
                uint256 currHeight = newHeight - 1;
                heightToHash[newHeight] = blockHash;
                while (!blockHeaders[currBlockHash].isCanonical) {
                    blockHeaders[currBlockHash].isCanonical = true;
                    heightToHash[currHeight] = currBlockHash;
                    currHeight--;
                    currBlockHash = blockHeaders[currBlockHash].prevBlock;
                }
                bytes32 commonAncestor = currBlockHash;
                currBlockHash = _latestBlockHash;
                currHeight = blockHeaders[_latestBlockHash].height;
                while (currBlockHash != commonAncestor) {
                    blockHeaders[currBlockHash].isCanonical = false;
                    if (currHeight > newHeight) {
                        // Canonical chain becomes shorter
                        heightToHash[currHeight] = bytes32(0);
                    }
                    currHeight--;
                    currBlockHash = blockHeaders[currBlockHash].prevBlock;
                }
                latestBlockHash = blockHash;
            } else {
                blockHeaders[blockHash].isCanonical = false;
            }
        }

        emit NewBlockHeader(blockHash, newHeight, header, latestUpdated);
    }

    /// @notice validate transaction proof
    function validate(
        uint256 blockHeight,
        bytes32 blockHash,
        bool requireSafe,
        uint256 transactionIndex,
        bytes calldata transactionData,
        bytes32[] calldata proof
    ) external view returns (bool) {
        require(transactionData.length > 64, "transactionData too short");

        if (blockHash == bytes32(0)) {
            blockHash = getBlockHashByHeight(blockHeight, requireSafe);
        } else {
            checkBlockHash(blockHash, requireSafe);
            require(blockHeight == 0, "blockHeight and blockHash cannot both be non-zero");
        }

        bytes32 h = sha256(abi.encode(sha256(transactionData)));
        for (uint256 i = 0; i < proof.length; i++) {
            if (transactionIndex % 2 == 0) {
                h = sha256(abi.encode(sha256(abi.encode(h, proof[i]))));
            } else {
                if (proof[i] == h) {
                    return false; // For odd number in a row, the last one must be at left
                }
                h = sha256(abi.encode(sha256(abi.encode(proof[i], h))));
            }
            transactionIndex /= 2;
        }

        if (transactionIndex != 0) {
            return false;
        }

        return bytes32(Endian.reverse256(uint256(h))) == blockHeaders[blockHash].merkleRoot;
    }

    function parseHeader(bytes memory header)
        public
        pure
        returns (
            int32 version,
            bytes32 blockHash,
            bytes32 prevBlock,
            bytes32 merkleRoot,
            uint32 timestamp,
            uint32 bits,
            uint32 nonce
        )
    {
        blockHash = bytes32(Endian.reverse256(uint256(sha256(abi.encode(sha256(header))))));
        version = int32(Endian.reverse32(BytesLib.toUint32(header, 0)));
        prevBlock = bytes32(Endian.reverse256(BytesLib.toUint256(header, 4)));
        merkleRoot = bytes32(Endian.reverse256(BytesLib.toUint256(header, 36)));
        timestamp = Endian.reverse32(BytesLib.toUint32(header, 68));
        bits = Endian.reverse32(BytesLib.toUint32(header, 72));
        nonce = Endian.reverse32(BytesLib.toUint32(header, 76));
    }

    function unparseHeader(
        int32 version,
        bytes32 prevBlock,
        bytes32 merkleRoot,
        uint32 timestamp,
        uint32 bits,
        uint32 nonce
    ) public pure returns (bytes memory) {
        bytes memory header = abi.encodePacked(
            Endian.reverse32(uint32(version)),
            Endian.reverse256(uint256(prevBlock)),
            Endian.reverse256(uint256(merkleRoot)),
            Endian.reverse32(timestamp),
            Endian.reverse32(bits),
            Endian.reverse32(nonce)
        );
        return header;
    }

    function bitsToTarget(uint32 bits) public pure returns (uint256) {
        // https://github.com/bitcoin/bitcoin/blob/44d8b13c81e5276eb610c99f227a4d090cc532f6/src/arith_uint256.cpp#L198
        uint256 nSize = bits >> 24;
        uint256 nWord = bits & 0x7fffff;
        require(nWord == 0 || (bits & 0x800000) == 0, "bits negative");
        require(
            nWord == 0 || !((nSize > 34) || (nWord > 0xff && nSize > 33) || (nWord > 0xffff && nSize > 32)),
            "bits overflow"
        );
        if (nSize <= 3) {
            return nWord >> 8 * (3 - nSize);
        } else {
            return nWord << 8 * (nSize - 3);
        }
    }

    function nextBlockBits(Header storage prevHeader, uint256 newHeight) internal view returns (uint32) {
        // https://github.com/bitcoin/bitcoin/blob/44d8b13c81e5276eb610c99f227a4d090cc532f6/src/pow.cpp#L49
        uint32 prevBits = prevHeader.bits;
        if (newHeight % difficultyAdjustmentInterval != 0) {
            return prevBits;
        }
        // We assume that a reorg of 2016 blocks will not occur.
        // If a non-canonical fork chain with 2016 blocks is produced, the difficulty retargeting may be wrong, but it does not affect security.
        uint32 periodStartTime = blockHeaders[heightToHash[newHeight - difficultyAdjustmentInterval]].timestamp;
        require(periodStartTime != 0, "Block not found");
        uint32 periodEndTime = prevHeader.timestamp;
        uint32 timespan = periodEndTime - periodStartTime;
        if (timespan < powTargetTimespan / 4) {
            timespan = powTargetTimespan / 4;
        }
        if (timespan > powTargetTimespan * 4) {
            timespan = powTargetTimespan * 4;
        }

        uint256 newTarget = bitsToTarget(prevBits) * timespan / powTargetTimespan;
        if (newTarget > powLimit) {
            newTarget = powLimit;
        }

        return targetToBits(newTarget);
    }

    function targetToBits(uint256 target) public pure returns (uint32) {
        // https://github.com/bitcoin/bitcoin/blob/44d8b13c81e5276eb610c99f227a4d090cc532f6/src/arith_uint256.cpp#L220
        uint256 nSize = 1;
        uint256 _target = target;
        if (_target >= 1 << 128) {
            nSize += 16;
            _target >>= 128;
        }
        if (_target >= 1 << 64) {
            nSize += 8;
            _target >>= 64;
        }
        if (_target >= 1 << 32) {
            nSize += 4;
            _target >>= 32;
        }
        if (_target >= 1 << 16) {
            nSize += 2;
            _target >>= 16;
        }
        if (_target >= 1 << 8) {
            nSize += 1;
        }

        uint256 nCompact = 0;
        if (nSize <= 3) {
            nCompact = target << 8 * (3 - nSize);
        } else {
            nCompact = target >> 8 * (nSize - 3);
        }
        if (nCompact & 0x00800000 != 0) {
            nCompact >>= 8;
            nSize++;
        }
        return uint32(nCompact | nSize << 24);
    }

    function targetToWork(uint256 target) public pure returns (int256) {
        // https://github.com/bitcoin/bitcoin/blob/44d8b13c81e5276eb610c99f227a4d090cc532f6/src/chain.cpp#L143
        return int256((~target / (target + 1)) + 1);
    }

    function bitsToWork(uint32 bits) public pure returns (int256) {
        return targetToWork(bitsToTarget(bits));
    }

    function isFinalizedByHeight(uint256 height) public view returns (bool) {
        require(heightToHash[height] != bytes32(0), "Block not found");
        return height + minConfirmations - 1 <= blockHeaders[latestBlockHash].height;
    }

    function isFinalizedByHash(bytes32 blockHash) public view returns (bool) {
        require(blockHeaders[blockHash].merkleRoot != bytes32(0), "Block not found");
        return blockHeaders[blockHash].isCanonical
            && blockHeaders[blockHash].height + minConfirmations - 1 <= blockHeaders[latestBlockHash].height;
    }

    function isCanonicalByHash(bytes32 blockHash) public view returns (bool) {
        require(blockHeaders[blockHash].merkleRoot != bytes32(0), "Block not found");
        return blockHeaders[blockHash].isCanonical;
    }

    function getBlockHashByHeight(uint256 height, bool requireSafe) public view returns (bytes32) {
        bytes32 blockHash = heightToHash[height];
        require(blockHash != bytes32(0), "Block not found");
        if (requireSafe) {
            require(height + minConfirmations - 1 <= blockHeaders[latestBlockHash].height, "No enough confirmations");
        }
        return blockHash;
    }

    function checkBlockHash(bytes32 blockHash, bool requireSafe) internal view {
        require(blockHeaders[blockHash].merkleRoot != bytes32(0), "Block not found");
        if (requireSafe) {
            require(blockHeaders[blockHash].isCanonical, "Block is not on the canonical chain");
            require(
                blockHeaders[blockHash].height + minConfirmations - 1 <= blockHeaders[latestBlockHash].height,
                "No enough confirmations"
            );
        }
    }

    function getBlockHeaderByHash(bytes32 blockHash, bool requireSafe) public view returns (bytes memory) {
        checkBlockHash(blockHash, requireSafe);
        Header storage header = blockHeaders[blockHash];
        return unparseHeader(
            header.version, header.prevBlock, header.merkleRoot, header.timestamp, header.bits, header.nonce
        );
    }

    function getBlockHeaderByHeight(uint256 height, bool requireSafe) public view returns (bytes memory) {
        bytes32 blockHash = getBlockHashByHeight(height, requireSafe);
        Header storage header = blockHeaders[blockHash];
        return unparseHeader(
            header.version, header.prevBlock, header.merkleRoot, header.timestamp, header.bits, header.nonce
        );
    }

    function getBlockHeaderStructByHash(bytes32 blockHash, bool requireSafe) public view returns (Header memory) {
        checkBlockHash(blockHash, requireSafe);
        return blockHeaders[blockHash];
    }

    function getBlockHeaderStructByHeight(uint256 height, bool requireSafe) public view returns (Header memory) {
        bytes32 blockHash = getBlockHashByHeight(height, requireSafe);
        return blockHeaders[blockHash];
    }

    function getBlockHeightByHash(bytes32 blockHash, bool requireSafe) public view returns (uint256) {
        checkBlockHash(blockHash, requireSafe);
        return blockHeaders[blockHash].height;
    }

    function getChainWorkSinceInitBlockByHash(bytes32 blockHash, bool requireSafe) public view returns (int256) {
        checkBlockHash(blockHash, requireSafe);
        return blockHeaders[blockHash].chainWorkSinceInitBlock;
    }

    function getChainWorkSinceInitBlockByHeight(uint256 height, bool requireSafe) public view returns (int256) {
        bytes32 blockHash = getBlockHashByHeight(height, requireSafe);
        return blockHeaders[blockHash].chainWorkSinceInitBlock;
    }

    function getBlockVersionByHash(bytes32 blockHash, bool requireSafe) public view returns (int32) {
        checkBlockHash(blockHash, requireSafe);
        return blockHeaders[blockHash].version;
    }

    function getBlockVersionByHeight(uint256 height, bool requireSafe) public view returns (int32) {
        bytes32 blockHash = getBlockHashByHeight(height, requireSafe);
        return blockHeaders[blockHash].version;
    }

    function getBlockPrevBlockByHash(bytes32 blockHash, bool requireSafe) public view returns (bytes32) {
        checkBlockHash(blockHash, requireSafe);
        return blockHeaders[blockHash].prevBlock;
    }

    function getBlockPrevBlockByHeight(uint256 height, bool requireSafe) public view returns (bytes32) {
        bytes32 blockHash = getBlockHashByHeight(height, requireSafe);
        return blockHeaders[blockHash].prevBlock;
    }

    function getBlockMerkleRootByHash(bytes32 blockHash, bool requireSafe) public view returns (bytes32) {
        checkBlockHash(blockHash, requireSafe);
        return blockHeaders[blockHash].merkleRoot;
    }

    function getBlockMerkleRootByHeight(uint256 height, bool requireSafe) public view returns (bytes32) {
        bytes32 blockHash = getBlockHashByHeight(height, requireSafe);
        return blockHeaders[blockHash].merkleRoot;
    }

    function getBlockTimestampByHash(bytes32 blockHash, bool requireSafe) public view returns (uint32) {
        checkBlockHash(blockHash, requireSafe);
        return blockHeaders[blockHash].timestamp;
    }

    function getBlockTimestampByHeight(uint256 height, bool requireSafe) public view returns (uint32) {
        bytes32 blockHash = getBlockHashByHeight(height, requireSafe);
        return blockHeaders[blockHash].timestamp;
    }

    function getBlockBitsByHash(bytes32 blockHash, bool requireSafe) public view returns (uint32) {
        checkBlockHash(blockHash, requireSafe);
        return blockHeaders[blockHash].bits;
    }

    function getBlockBitsByHeight(uint256 height, bool requireSafe) public view returns (uint32) {
        bytes32 blockHash = getBlockHashByHeight(height, requireSafe);
        return blockHeaders[blockHash].bits;
    }

    function getBlockNonceByHash(bytes32 blockHash, bool requireSafe) public view returns (uint32) {
        checkBlockHash(blockHash, requireSafe);
        return blockHeaders[blockHash].nonce;
    }

    function getBlockNonceByHeight(uint256 height, bool requireSafe) public view returns (uint32) {
        bytes32 blockHash = getBlockHashByHeight(height, requireSafe);
        return blockHeaders[blockHash].nonce;
    }
}