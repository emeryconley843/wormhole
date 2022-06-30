// contracts/Messages.sol
// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "./Getters.sol";
import "./Setters.sol";
import "./Structs.sol";
import "./libraries/external/BytesLib.sol";


contract Messages is Getters, Setters {
    using BytesLib for bytes;

    /// @dev parseAndVerifyVM serves to parse an encodedVM and wholy validate it for consumption
    function parseAndVerifyVM(bytes calldata encodedVM) public view returns (Structs.VM memory vm, bool valid, string memory reason) {
        vm = parseVM(encodedVM);
        (valid, reason) = verifyVM(vm);
    }

    /// caches results
    function parseAndVerifyVM2(bytes calldata encodedVM) public returns (Structs.VM2 memory vm, bool valid, string memory reason) {
        vm = parseVM2(encodedVM);
        (valid, reason) = verifyBatchHeader(vm.header);

        for (uint i = 0; i < vm.header.hashes.length; i++) {
            updateVerifiedCacheStatus(vm.header.hashes[i], true);
        }

        return (vm, valid, reason);
    }

    function wipeBatchCache(Structs.BatchHeader memory header) public {
        for (uint i = 0; i < header.hashes.length; i++) {
            updateVerifiedCacheStatus(header.hashes[i], false);
        }
    }

    function parseAndVerifyVM3(bytes calldata encodedVM) public view returns (Structs.VM3 memory vm, bool valid, string memory reason) {
        vm = parseVM3(encodedVM);
        (valid, reason) = verifyVM3(vm);
    }

    // TODO(csongor): think about the name
    // Can't extend the existing function because it would introduce a breaking
    // change.
    function parseAndVerifyVAA(
        bytes calldata encodedVM
    ) public view returns (Structs.Observation memory observation, bool valid, string memory reason) {
        uint8 version = encodedVM.toUint8(0);
        if (version == 1) {
            Structs.VM memory vm;
            (vm, valid, reason) = parseAndVerifyVM(encodedVM);

            observation.timestamp = vm.timestamp;
            observation.nonce = vm.nonce;
            observation.emitterChainId = vm.emitterChainId;
            observation.emitterAddress = vm.emitterAddress;
            observation.sequence = vm.sequence;
            observation.consistencyLevel = vm.consistencyLevel;
            observation.payload = vm.payload;
        } else if (version == 3) {
            Structs.VM3 memory vm;
            (vm, valid, reason) = parseAndVerifyVM3(encodedVM);
            observation = vm.observation;
        } else {
            valid = false;
            reason = "Invalid version";
        }

    }

    function verifyHeader(Structs.Header memory vm) internal view returns (bool valid, string memory reason) {
        // TODO(csongor): we should double check that all of the logic here is
        // safe to skip if the hash is cached. I think it's safe, because it
        // means that the checks below have already been performed.
        if (verifiedHashCached(vm.hash)) {
            return (true, "");
        }

        /// @dev Obtain the current guardianSet for the guardianSetIndex provided
        Structs.GuardianSet memory guardianSet = getGuardianSet(vm.guardianSetIndex);

       /**
        * @dev Checks whether the guardianSet has zero keys
        * WARNING: This keys check is critical to ensure the guardianSet has keys present AND to ensure
        * that guardianSet key size doesn't fall to zero and negatively impact quorum assessment.  If guardianSet
        * key length is 0 and vm.signatures length is 0, this could compromise the integrity of both vm and
        * signature verification.
        */
        if(guardianSet.keys.length == 0){
            return (false, "invalid guardian set");
        }

        /// @dev Checks if VM guardian set index matches the current index (unless the current set is expired).
        if(vm.guardianSetIndex != getCurrentGuardianSetIndex() && guardianSet.expirationTime < block.timestamp){
            return (false, "guardian set has expired");
        }

       /**
        * @dev We're using a fixed point number transformation with 1 decimal to deal with rounding.
        *   WARNING: This quorum check is critical to assessing whether we have enough Guardian signatures to validate a VM
        *   if making any changes to this, obtain additional peer review. If guardianSet key length is 0 and
        *   vm.signatures length is 0, this could compromise the integrity of both vm and signature verification.
        */
        if (vm.signatures.length < quorum(guardianSet.keys.length)){
            return (false, "no quorum");
        }

        /// @dev Verify the proposed vm.signatures against the guardianSet
        (bool signaturesValid, string memory invalidReason) = verifySignatures(vm.hash, vm.signatures, guardianSet);
        if(!signaturesValid){
            return (false, invalidReason);
        }

        /// If we are here, we've validated the VM is a valid multi-sig that matches the guardianSet.
        return (true, "");
    }

   /**
    * @dev `verifyVM` serves to validate an arbitrary vm against a valid Guardian set
    *  - it aims to make sure the VM is for a known guardianSet
    *  - it aims to ensure the guardianSet is not expired
    *  - it aims to ensure the VM has reached quorum
    *  - it aims to verify the signatures provided against the guardianSet
    */
    function verifyVM(Structs.VM memory vm) public view returns (bool valid, string memory reason) {
        Structs.Header memory header;
        header.guardianSetIndex = vm.guardianSetIndex;
        header.signatures = vm.signatures;
        header.hash = vm.hash;
        return verifyHeader(header);
    }

    function verifyVM3(Structs.VM3 memory vm) public view returns (bool valid, string memory reason) {
        if (verifiedHashCached(vm.hash)) {
            return (true, "");
        } else {
            return (false, "Could not find hash in cache");
        }
    }

    function verifyBatchHeader(Structs.BatchHeader memory vm) public view returns (bool valid, string memory reason) {
        Structs.Header memory header;
        header.guardianSetIndex = vm.guardianSetIndex;
        header.signatures = vm.signatures;
        header.hash = vm.hash;
        return verifyHeader(header);
    }

    /**
     * @dev verifySignatures serves to validate arbitrary sigatures against an arbitrary guardianSet
     *  - it intentionally does not solve for expectations within guardianSet (you should use verifyVM if you need these protections)
     *  - it intentioanlly does not solve for quorum (you should use verifyVM if you need these protections)
     *  - it intentionally returns true when signatures is an empty set (you should use verifyVM if you need these protections)
     */
    function verifySignatures(bytes32 hash, Structs.Signature[] memory signatures, Structs.GuardianSet memory guardianSet) public pure returns (bool valid, string memory reason) {
        uint8 lastIndex = 0;
        uint256 guardianCount = guardianSet.keys.length;
        for (uint i = 0; i < signatures.length; i++) {
            Structs.Signature memory sig = signatures[i];

            /// Ensure that provided signature indices are ascending only
            require(i == 0 || sig.guardianIndex > lastIndex, "signature indices must be ascending");
            lastIndex = sig.guardianIndex;

            /// @dev Ensure that the provided signature index is within the
            /// bounds of the guardianSet. This is implicitly checked by the array
            /// index operation below, so this check is technically redundant.
            /// However, reverting explicitly here ensures that a bug is not
            /// introduced accidentally later due to the nontrivial storage
            /// semantics of solidity.
            require(sig.guardianIndex < guardianCount, "guardian index out of bounds");

            /// Check to see if the signer of the signature does not match a specific Guardian key at the provided index
            if(ecrecover(hash, sig.v, sig.r, sig.s) != guardianSet.keys[sig.guardianIndex]){
                return (false, "VM signature invalid");
            }
        }

        /// If we are here, we've validated that the provided signatures are valid for the provided guardianSet
        return (true, "");
    }

    function parseObservation(
        uint256 start,
        uint256 length,
        bytes memory encodedObservation
    ) internal pure returns (Structs.Observation memory observation) {
        uint256 index = start;

        observation.timestamp = encodedObservation.toUint32(index);
        index += 4;

        observation.nonce = encodedObservation.toUint32(index);
        index += 4;

        observation.emitterChainId = encodedObservation.toUint16(index);
        index += 2;

        observation.emitterAddress = encodedObservation.toBytes32(index);
        index += 32;

        observation.sequence = encodedObservation.toUint64(index);
        index += 8;

        observation.consistencyLevel = encodedObservation.toUint8(index);
        index += 1;

        uint256 consumed = index - start;

        require(length >= consumed, "Insufficient observation length");

        observation.payload = encodedObservation.slice(index, length - consumed);
    }

    function parseSignatures(
        uint256 start,
        uint256 signersLen,
        bytes memory data
    ) internal pure returns (Structs.Signature[] memory signatures) {
        uint256 index = start;
        signatures = new Structs.Signature[](signersLen);
        for (uint i = 0; i < signersLen; i++) {
            signatures[i].guardianIndex = data.toUint8(index);
            index += 1;

            signatures[i].r = data.toBytes32(index);
            index += 32;
            signatures[i].s = data.toBytes32(index);
            index += 32;
            signatures[i].v = data.toUint8(index) + 27;
            index += 1;
        }
    }


    /**
     * @dev parseVM serves to parse an encodedVM into a vm struct
     *  - it intentionally performs no validation functions, it simply parses raw into a struct
     */
    function parseVM(bytes memory encodedVM) public pure virtual returns (Structs.VM memory vm) {
        uint256 index = 0;

        vm.version = encodedVM.toUint8(index);
        index += 1;
        // SECURITY: Note that currently the VM.version is not part of the hash 
        // and for reasons described below it cannot be made part of the hash. 
        // This means that this field's integrity is not protected and cannot be trusted. 
        // This is not a problem today since there is only one accepted version, but it 
        // could be a problem if we wanted to allow other versions in the future. 
        require(vm.version == 1, "VM version incompatible"); 

        vm.guardianSetIndex = encodedVM.toUint32(index);
        index += 4;

        // Parse Signatures
        uint256 signersLen = encodedVM.toUint8(index);
        index += 1;

        vm.signatures = parseSignatures(index, signersLen, encodedVM);
        index += 66*signersLen;

        /*
        Hash the body

        SECURITY: Do not change the way the hash of a VM is computed! 
        Changing it could result into two different hashes for the same observation. 
        But xDapps rely on the hash of an observation for replay protection.
        */
        bytes memory body = encodedVM.slice(index, encodedVM.length - index);
        vm.hash = keccak256(abi.encodePacked(keccak256(body)));

        // TODO(csongor): we could optimise gas here by manually inlining these functions if need be
        Structs.Observation memory observation = parseObservation(index, encodedVM.length - index, encodedVM);

        vm.timestamp = observation.timestamp;
        vm.nonce = observation.nonce;
        vm.emitterChainId = observation.emitterChainId;
        vm.emitterAddress = observation.emitterAddress;
        vm.sequence = observation.sequence;
        vm.consistencyLevel = observation.consistencyLevel;
        vm.payload = observation.payload;
    }

    function parseVM2(bytes memory encodedVM) public pure virtual returns (Structs.VM2 memory vm) {
        uint256 index = 0;

        vm.header.version = encodedVM.toUint8(index);
        index += 1;
        require(vm.header.version == 2, "VM version incompatible");

        vm.header.guardianSetIndex = encodedVM.toUint32(index);
        index += 4;

        // Parse Signatures
        uint256 signersLen = encodedVM.toUint8(index);
        index += 1;

        vm.header.signatures = parseSignatures(index, signersLen, encodedVM);
        index += 66*signersLen;

        uint8 hashesLen = encodedVM.toUint8(index);

        // hash the hashes
        bytes memory body = encodedVM.slice(index, hashesLen * 32);
        vm.header.hash = keccak256(abi.encodePacked(keccak256(body)));

        // parse hashes
        vm.header.hashes = new bytes32[](hashesLen);
        for (uint8 i = 0; i < hashesLen; i++) {
            vm.header.hashes[i] = encodedVM.toBytes32(index);
            index += 32;
        }

        uint8 observationsLen = encodedVM.toUint8(index);

        vm.observations = new bytes[](observationsLen);
        uint32 observationLen;
        for (uint8 i = 0; i < observationsLen; i++) {
            observationLen = encodedVM.toUint32(index);
            index += 1;
            // TODO(csongor): we add "3" to the observation here so
            // parseAndVerifyVAA can pick up whether it's given a V1 or a V3.
            // Is there a better way?
            vm.observations[i] = abi.encodePacked(uint8(3), encodedVM.slice(index, observationLen));
            index += observationLen;
        }
    }

    function parseVM3(bytes memory encodedVM) public pure virtual returns (Structs.VM3 memory vm) {
        uint256 index = 3;

        vm.version = encodedVM.toUint8(index);
        index += 1;
        require(vm.version == 3, "VM version incompatible");
        vm.observation = parseObservation(index, encodedVM.length, encodedVM);

        // Hash the body
        bytes memory body = encodedVM.slice(index, encodedVM.length - index);
        vm.hash = keccak256(abi.encodePacked(keccak256(body)));
    }

    /**
     * @dev quorum serves solely to determine the number of signatures required to acheive quorum
     */
    function quorum(uint numGuardians) public pure virtual returns (uint numSignaturesRequiredForQuorum) {
        // The max number of guardians is 255
        require(numGuardians < 256, "too many guardians");
        return ((numGuardians * 2) / 3) + 1;
    }
}
