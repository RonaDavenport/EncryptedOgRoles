# Encrypted OG Roles

Privacy–preserving OG role assignment for onchain communities, built on **Zama FHEVM**.

Members submit **encrypted contribution scores** for a given badge ID. The smart contract holds an **encrypted minimum threshold** per badge and computes whether the member qualifies as OG **fully under FHE**. Nobody (including the contract owner) ever sees raw contribution numbers on‑chain.

The frontend uses Zama’s **Relayer SDK** so that each user can privately decrypt their own OG flag via `userDecrypt`. There is **no public certificate** in this project – OG status is visible only to the wallet owner.

---

## Table of contents

* [Concept](#concept)
* [How OG evaluation works](#how-og-evaluation-works)
* [Smart contract](#smart-contract)

  * [Contract address](#contract-address)
  * [Interface](#interface)
  * [Access control](#access-control)
* [Frontend](#frontend)

  * [Member flow](#member-flow)
  * [Admin flow](#admin-flow)
* [Project structure](#project-structure)
* [Development & local setup](#development--local-setup)
* [Security & privacy notes](#security--privacy-notes)

---

## Concept

**Goal:** allow communities to assign *OG roles* based on early / meaningful contribution, without ever revealing the exact contribution numbers on‑chain.

* Each **badge** (e.g. `Wave #1`, `Early Builder`, `Genesis Farmer`) has an **encrypted minimum contribution threshold**.
* Members submit their contribution score **encrypted**.
* The contract compares *encrypted contribution* vs *encrypted threshold* using Zama’s FHE operations.
* The result is an **encrypted boolean OG flag** stored per `(member, badgeId)`.
* Members decrypt their own flag via `userDecrypt` in the frontend.

No one can see actual contribution numbers on-chain, and there’s no public OG certificate – OG status is *personal*.

---

## How OG evaluation works

High‑level protocol:

1. **Admin encrypts OG threshold**

   * Off‑chain, using Relayer SDK, admin creates an encrypted input for the contract with `add32(minContribution)`.
   * Gateway returns a `bytes32` handle + proof.
   * Admin calls `createOgBadge` or `updateOgBadge` with `encMinScore` + `proof`.
   * Contract stores `eMinScore` as an encrypted `euint32` and keeps decryption rights via FHE ACL.

2. **Member submits encrypted contribution**

   * Member encrypts their contribution score via Relayer SDK with `add32(contribution)`.
   * Calls `evaluateOgStatus(badgeId, encContribution, proof)`.
   * Contract ingests `encContribution` and evaluates:

     * `eIsOg = FHE.ge(eContribution, eMinScore)`
   * Encrypted result (`eIsOg`) is stored in a mapping alongside `eContribution`.

3. **Member decrypts OG flag**

   * Frontend calls `getMyOgStatusHandles(badgeId)` → returns:

     * `contributionHandle` (encrypted contribution)
     * `ogFlagHandle` (encrypted OG boolean)
     * `decided` (whether any attempt was processed)
   * Frontend passes both handles to `userDecrypt` with a short‑lived keypair and EIP‑712 signature.
   * SDK returns decrypted values client‑side; frontend converts the OG flag into a simple `OG / not OG` label.

All comparisons and decisions happen on-chain in encrypted space. Only the user ever sees their cleartext OG status.

---

## Smart contract

### Contract address

Deployed on **Ethereum Sepolia**:

```text
0xDF1b0dD09d05E196b74605F8b203c07a2027f2Ac
```

### Interface

The contract is built on top of **Zama FHEVM** (`FHE.sol` + `ZamaEthereumConfig`) and exposes a small, focused API.

#### Admin (owner‑only)

* `createOgBadge(uint256 badgeId, externalEuint32 encMinScore, bytes proof)`

  * Creates a new OG badge with an encrypted minimum contribution threshold.
  * Fails if `badgeId` already exists.
* `updateOgBadge(uint256 badgeId, externalEuint32 encMinScore, bytes proof)`

  * Updates the encrypted minimum contribution threshold for an existing badge.
* `getBadgePolicyHandle(uint256 badgeId) external view onlyOwner returns (bytes32)`

  * Returns the handle of the encrypted minimum score for off‑chain analytics or checks.

#### Member actions

* `evaluateOgStatus(uint256 badgeId, externalEuint32 encContribution, bytes proof)`

  * Ingests the member’s encrypted contribution for a given badge.
  * Computes an encrypted OG flag under FHE and stores `(eContribution, eIsOg, decided)`.
* `getMyOgStatusHandles(uint256 badgeId) external view returns (bytes32 contributionHandle, bytes32 ogFlagHandle, bool decided)`

  * Returns the ciphertext handles for the caller’s contribution and OG flag for this badge.

#### Metadata

* `getBadgeMeta(uint256 badgeId) external view returns (bool exists)`

  * Simple existence check for badge configuration (no FHE ops).

#### Ownership

* `owner() external view returns (address)`
* `transferOwnership(address newOwner) external onlyOwner`

Access control is implemented via `onlyOwner` and FHE ACLs (`FHE.allow`, `FHE.allowThis`) inside the contract.

> **Note:** The actual Solidity file uses `euint32` / `externalEuint32` types and FHE operations from Zama’s official libraries. All view functions only expose handles (no FHE computation in views).

---

## Frontend

The frontend is a single‑page app (`index.html`) using:

* **Ethers v6** (BrowserProvider + Contract) over `window.ethereum` (Metamask, etc.)
* **Zama Relayer SDK JS** `0.3.0-5` for:

  * Encrypted inputs (`createEncryptedInput` + `add32`)
  * `userDecrypt` for per‑user decryption

It is intentionally UI‑heavy and dependency‑light (pure HTML + CSS + vanilla JS). All cryptographic heavy lifting is done by the Relayer SDK and Zama FHEVM.

### Member flow

From the user’s perspective:

1. **Connect wallet**

   * Click `Connect wallet`.
   * App ensures you are on Sepolia (auto‑switch / add network if needed).

2. **Submit encrypted contribution**

   * Enter a `Badge ID` (e.g. `1` for Wave 1 OG).
   * Enter your `Contribution score`.
   * Click **“Encrypt & submit”**.
   * Frontend:

     * Encrypts the score off‑chain via Relayer (`add32(contribution)`).
     * Sends `evaluateOgStatus(badgeId, handle, proof)`.

3. **Decrypt OG status**

   * After the transaction confirms, click **“Decrypt my OG status”**.
   * Frontend:

     * Calls `getMyOgStatusHandles(badgeId)` to fetch handles.
     * Builds a `userDecrypt` request with a short‑lived keypair and EIP‑712 signature.
     * Interprets the result via `normalizeDecryptedValue` and displays:

       * `OG (true)` or `not OG (false)`
       * The raw cipher handle for debugging.

All decrypted values are kept in memory and never sent to the contract.

### Admin flow

Visible in the right‑hand panel when the connected address is the contract owner.

1. **Configure / update a badge**

   * Set `Badge ID`.
   * Set `Minimum contribution to be OG` (cleartext in the admin UI, but encrypted before on‑chain).
   * Click **“Encrypt & create / update badge”**.
   * Frontend:

     * Encrypts the threshold using Relayer (`add32(minContribution)`).
     * Calls `createOgBadge` if badge doesn’t exist yet, otherwise `updateOgBadge`.

2. **Iterate**

   * You can adjust thresholds at any time; badge definitions are flexible and do not leak clear thresholds on‑chain.

---

## Project structure

Suggested repo layout:

```text
.
├─ contracts/
│  └─ EncryptedOgRoles.sol        # FHEVM smart contract for OG role evaluation
├─ frontend/
│  └─ index.html                  # Single-page frontend (HTML + CSS + JS)
├─ README.md                      # This file
└─ package.json                   # (optional) scripts for tooling / linters
```

If you use Hardhat / Foundry, a typical Hardhat layout might look like:

```text
contracts/EncryptedOgRoles.sol
scripts/deploy.ts
hardhat.config.ts
frontend/index.html
```

Adapt to your toolchain as needed.

---

## Development & local setup

### Requirements

* Node.js (LTS)
* A browser wallet (MetaMask) connected to **Ethereum Sepolia**
* A running instance of Zama’s **Relayer** and **Gateway**, or the official public testnet endpoints

### Run frontend locally

From the `frontend` folder:

```bash
# Simple static server (example with npx)
npx serve .
```

Then open:

```text
http://localhost:3000
# or whatever port your static server uses
```

If you proxy Relayer/Gateway via localhost, the frontend will automatically use:

* `https://localhost:3443/relayer`
* `https://localhost:3443/gateway`

Otherwise it falls back to Zama’s public testnet endpoints.

### Deploy contract (example with Hardhat)

Very high‑level sketch:

```ts
// scripts/deploy.ts
const factory = await ethers.getContractFactory("EncryptedOgRoles");
const contract = await factory.deploy();
await contract.waitForDeployment();
console.log("EncryptedOgRoles deployed at", await contract.getAddress());
```

Update the address in `frontend/index.html` (`CONTRACT_ADDRESS`) after deployment.

---

## Security & privacy notes

* The contract never stores raw numbers – only **encrypted `euint32` contributions** and **encrypted `ebool` OG flags**.
* All comparisons (`>= threshold`) are performed via `FHE.ge` under encryption.
* Views only return **handles**, not cleartext values.
* Decryption is always opt‑in and **per‑user**, using `userDecrypt` with EIP‑712 signing.
* There is **no public OG certificate** in this design; OG status is private to each wallet.

If you extend the protocol (e.g. add public badges, leaderboards, or cross‑contract checks), keep these principles:

1. No FHE operations in `view` / `pure` functions.
2. Only ever expose encrypted handles from on‑chain state.
3. Use `FHE.allowThis`, `FHE.allow`, and `FHE.allowTransient` appropriately to control who can decrypt.
4. Keep any JSON/logging that touches `BigInt` safe by using a custom `JSON.stringify` replacer (as implemented in the frontend).

---

Happy building, and feel free to adapt this OG roles primitive to your own community logic (tiers, seasons, multi‑badge progressions, etc.) while keeping contributions fully private.
