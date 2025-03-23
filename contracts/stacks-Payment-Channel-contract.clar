;; Layer 2 Payment Channel Network
;; A network of payment channels for micro-transactions with minimal fees

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-channel-exists (err u102))
(define-constant err-channel-not-found (err u103))
(define-constant err-insufficient-funds (err u104))
(define-constant err-channel-closed (err u105))
(define-constant err-invalid-signature (err u106))
(define-constant err-timelock-not-expired (err u107))
(define-constant err-invalid-state (err u108))
(define-constant err-invalid-amount (err u109))
(define-constant err-invalid-route (err u110))
(define-constant err-route-capacity-exceeded (err u111))
(define-constant err-invalid-balance-proof (err u112))
(define-constant err-invalid-htlc (err u113))
(define-constant err-htlc-expired (err u114))
(define-constant err-incorrect-preimage (err u115))
(define-constant err-route-not-found (err u116))
(define-constant err-self-payment (err u117))
(define-constant err-different-amounts (err u118))
(define-constant err-already-registered (err u119))
(define-constant err-not-registered (err u120))

;; State Enum - Channel states
(define-data-var next-channel-id uint u1)
(define-data-var next-htlc-id uint u1)
(define-data-var protocol-fee-percentage uint u20) ;; 0.2% in basis points
(define-data-var dispute-timeout uint u1440) ;; ~10 days (assuming 144 blocks/day)
(define-data-var settle-timeout uint u144) ;; ~1 day
(define-data-var min-channel-deposit uint u1000000) ;; 0.01 STX
(define-data-var network-participants (list 1000 principal) (list))

;; Channel state enumeration
;; 0 = Open, 1 = Closing, 2 = Settled
(define-data-var channel-states (list 3 (string-ascii 12)) (list "Open" "Closing" "Settled"))

;; Participant registry for routing
(define-map participants
  { participant: principal }
  {
    active: bool,
    total-channels: uint,
    total-capacity: uint,
    reputation-score: uint, ;; 0-100 score
    last-active: uint       ;; block height
  }
)
;; Channel structure
(define-map channels
  { channel-id: uint }
  {
    participant1: principal,
    participant2: principal,
    capacity: uint,
    participant1-balance: uint,
    participant2-balance: uint,
    participant1-nonce: uint,
    participant2-nonce: uint,
    open-block: uint,
    state: uint,
    closing-initiated: (optional uint),
    closing-initiator: (optional principal),
    settle-block: (optional uint)
  }
)

;; Channel by participants
(define-map participant-channels
  { participant1: principal, participant2: principal }
  { channel-id: uint }
)

;; Hashed Time-Locked Contracts for multi-hop routing
(define-map htlcs
  { htlc-id: uint }
  {
    channel-id: uint,
    sender: principal,
    receiver: principal,
    amount: uint,
    hashlock: (buff 32),
    timelock: uint,
    preimage: (optional (buff 32)),
    claimed: bool,
    refunded: bool,
    created-at: uint
  }
)

;; Routing table for path finding
(define-map routing-edges
  { from: principal, to: principal }
  {
    channel-id: uint,
    capacity: uint,
    fee-rate: uint,
    last-updated: uint
  }
)

;; Balance proofs for off-chain state
(define-map balance-proofs
  { channel-id: uint, participant: principal }
  {
    nonce: uint,
    balance: uint,
    signature: (buff 65)
  }
)
;; Initialize the contract
(define-public (initialize)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Initialize default settings
    (var-set dispute-timeout u1440)
    (var-set settle-timeout u144)
    (var-set protocol-fee-percentage u20)
    
    (ok true)
  )
)

;; Register as network participant
(define-public (register-participant)
  (let (
    (participant tx-sender)
    (existing-record (map-get? participants { participant: participant }))
  )
    (asserts! (is-none existing-record) err-already-registered)
    
    ;; Add to participant registry
    (map-set participants
      { participant: participant }
      {
        active: true,
        total-channels: u0,
        total-capacity: u0,
        reputation-score: u70, ;; Start with neutral reputation
        last-active: block-height
      }
    )
    
    ;; Add to participant list
    (var-set network-participants (append (var-get network-participants) participant))
    
    (ok true)
  )
)

;; Deregister from network
(define-public (deregister-participant)
  (let (
    (participant tx-sender)
    (existing-record (map-get? participants { participant: participant }))
  )
    (asserts! (is-some existing-record) err-not-registered)
    
    ;; Note: Don't actually delete, just mark as inactive
    (map-set participants
      { participant: participant }
      (merge (unwrap-panic existing-record) { active: false })
    )
    
    (ok true)
  )
)