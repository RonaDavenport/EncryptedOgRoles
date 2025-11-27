// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * EncryptedOgRoles
 *
 * Privacy-preserving OG role assignment for communities:
 * - The community owner configures encrypted minimum contribution thresholds
 *   for one or more "OG waves" / badge IDs.
 * - Contributors submit their own encrypted "early contribution" score.
 * - The contract evaluates OG / non-OG fully under FHE (score >= encrypted min).
 * - Raw scores and OG flags stay private; users can decrypt their own result
 *   via the Relayer SDK (userDecrypt flow).
 * - There is NO public certificate / opt-in: OG status is private to the user.
 *
 * Design notes:
 * - Uses Zama FHEVM official Solidity library.
 * - No deprecated FHE APIs are used.
 * - No FHE ops in view/pure functions (views only expose handles).
 * - Access control via FHE.allow / FHE.allowThis.
 */

import {
  FHE,
  ebool,
  euint32,
  externalEuint32
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedOgRoles is ZamaEthereumConfig {
  // -------- Ownable --------
  address public owner;

  modifier onlyOwner() {
    require(msg.sender == owner, "Not owner");
    _;
  }

  constructor() {
    owner = msg.sender;
  }

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    owner = newOwner;
  }

  // -------- Simple nonReentrant guard (future-proof for payable flows) --------
  uint256 private _locked = 1;

  modifier nonReentrant() {
    require(_locked == 1, "reentrancy");
    _locked = 2;
    _;
    _locked = 1;
  }

  // ---------------------------------------------------------------------------
  // OG badge configuration (encrypted policy per badgeId)
  // ---------------------------------------------------------------------------

  /**
   * Each OG "badge" (or wave/role) is defined by an encrypted minimum
   * contribution score required to qualify as OG.
   *
   * The meaning of "contribution score" is left to the off-chain logic /
   * community: it could be an activity index, points from another system,
   * weighted timestamps, etc. On-chain we only see encrypted values.
   */
  struct OgBadgeConfig {
    bool exists;
    euint32 eMinContribution; // encrypted minimum contribution required
  }

  // badgeId => OgBadgeConfig
  mapping(uint256 => OgBadgeConfig) private badges;

  event OgBadgeCreated(uint256 indexed badgeId);
  event OgBadgeUpdated(uint256 indexed badgeId);
  event OgBadgeMinContributionUpdated(uint256 indexed badgeId);

  /**
   * Create a new OG badge with an encrypted minimum contribution score.
   *
   * @param badgeId          Arbitrary identifier (e.g. 1, 2, "early wave").
   * @param encMinScore      External encrypted min contribution handle.
   * @param proof            Coprocessor attestation for encMinScore.
   */
  function createOgBadge(
    uint256 badgeId,
    externalEuint32 encMinScore,
    bytes calldata proof
  ) external onlyOwner {
    require(!badges[badgeId].exists, "Badge already exists");

    // Ingest encrypted threshold
    euint32 eMin = FHE.fromExternal(encMinScore, proof);

    // Contract needs long-term access to this encrypted threshold
    FHE.allowThis(eMin);

    badges[badgeId] = OgBadgeConfig({
      exists: true,
      eMinContribution: eMin
    });

    emit OgBadgeCreated(badgeId);
    emit OgBadgeMinContributionUpdated(badgeId);
  }

  /**
   * Update encrypted minimum contribution for an existing OG badge.
   * Passing zero-handle + empty proof skips the update.
   */
  function updateOgBadge(
    uint256 badgeId,
    externalEuint32 encMinScore,
    bytes calldata proof
  ) external onlyOwner {
    OgBadgeConfig storage B = badges[badgeId];
    require(B.exists, "Badge does not exist");

    // Optional update of minimum contribution:
    if (proof.length != 0) {
      euint32 eMin = FHE.fromExternal(encMinScore, proof);
      FHE.allowThis(eMin);
      B.eMinContribution = eMin;
      emit OgBadgeMinContributionUpdated(badgeId);
    }

    emit OgBadgeUpdated(badgeId);
  }

  /**
   * Lightweight metadata getter (no FHE operations).
   * Only reveals whether a badge is configured.
   */
  function getBadgeMeta(uint256 badgeId)
    external
    view
    returns (bool exists)
  {
    OgBadgeConfig storage B = badges[badgeId];
    return B.exists;
  }

  // ---------------------------------------------------------------------------
  // Contributor OG status (encrypted scores and encrypted OG flags)
  // ---------------------------------------------------------------------------

  /**
   * For each contributor and badge:
   * - eContribution: encrypted user-submitted contribution score.
   * - eIsOg:         encrypted OG flag (contribution >= eMinContribution).
   * - decided:       true once at least one evaluation is processed.
   */
  struct OgStatus {
    euint32 eContribution;
    ebool   eIsOg;
    bool    decided;
  }

  // contributor => badgeId => OgStatus
  mapping(address => mapping(uint256 => OgStatus)) private ogStatuses;

  event OgContributionEvaluated(
    address indexed contributor,
    uint256 indexed badgeId,
    bytes32 contributionHandle,
    bytes32 ogFlagHandle
  );

  /**
   * Submit encrypted contribution for an OG badge and get an encrypted OG flag.
   *
   * Frontend flow (high-level):
   * 1) Off-chain, compute contribution score (any logic).
   * 2) Encrypt score with Relayer SDK (createEncryptedInput).
   * 3) Obtain externalEuint32 + proof from the Gateway.
   * 4) Call this function with encContribution + proof.
   * 5) Use getMyOgStatusHandles(...) + userDecrypt(...) to display the result
   *    (OG or not) privately to the contributor.
   */
  function evaluateOgStatus(
    uint256 badgeId,
    externalEuint32 encContribution,
    bytes calldata proof
  ) external nonReentrant {
    OgBadgeConfig storage B = badges[badgeId];
    require(B.exists, "Badge does not exist");

    OgStatus storage S = ogStatuses[msg.sender][badgeId];

    // Ingest encrypted contribution score
    euint32 eContribution = FHE.fromExternal(encContribution, proof);

    // Authorize contract and contributor on this ciphertext
    FHE.allowThis(eContribution);
    FHE.allow(eContribution, msg.sender);

    // Compare to encrypted minimum contribution (all under FHE)
    ebool eIsOg = FHE.ge(eContribution, B.eMinContribution);

    // Persist status
    S.eContribution = eContribution;
    S.eIsOg = eIsOg;
    S.decided = true;

    // Ensure contract keeps rights on stored ciphertexts
    FHE.allowThis(S.eContribution);
    FHE.allowThis(S.eIsOg);

    // Allow contributor to decrypt privately (userDecrypt)
    FHE.allow(S.eContribution, msg.sender);
    FHE.allow(S.eIsOg, msg.sender);

    emit OgContributionEvaluated(
      msg.sender,
      badgeId,
      FHE.toBytes32(S.eContribution),
      FHE.toBytes32(S.eIsOg)
    );
  }

  // ---------------------------------------------------------------------------
  // Getters (handles only, no FHE ops, no public certificates)
  // ---------------------------------------------------------------------------

  /**
   * Returns encrypted handles for the caller's OG status for a given badge:
   * - contributionHandle: encrypted contribution score (userDecrypt only).
   * - ogFlagHandle:       encrypted OG flag (userDecrypt only).
   * - decided:            whether any evaluation was processed.
   *
   * The frontend uses these handles with Relayer SDK's userDecrypt to
   * reveal the cleartext only to the contributor (off-chain).
   */
  function getMyOgStatusHandles(uint256 badgeId)
    external
    view
    returns (bytes32 contributionHandle, bytes32 ogFlagHandle, bool decided)
  {
    OgStatus storage S = ogStatuses[msg.sender][badgeId];
    return (
      FHE.toBytes32(S.eContribution),
      FHE.toBytes32(S.eIsOg),
      S.decided
    );
  }

  /**
   * Helper to expose the encrypted minimum contribution handle for a badge.
   * This can be used for owner-side analytics or verification flows.
   *
   * NOTE:
   * - This handle is NOT publicly decryptable by default.
   * - Only parties with ACL rights (typically this contract) can use it.
   */
  function getBadgePolicyHandle(uint256 badgeId)
    external
    view
    onlyOwner
    returns (bytes32 minContributionHandle)
  {
    OgBadgeConfig storage B = badges[badgeId];
    require(B.exists, "Badge does not exist");
    return FHE.toBytes32(B.eMinContribution);
  }
}
