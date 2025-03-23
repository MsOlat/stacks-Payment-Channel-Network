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
;; Open a new payment channel
(define-public (open-channel (participant2 principal) (deposit1 uint) (deposit2 uint))
  (let (
    (participant1 tx-sender)
    (channel-id (var-get next-channel-id))
  )
    ;; Ensure not opening channel with self
    (asserts! (not (is-eq participant1 participant2)) err-self-payment)
    
    ;; Ensure deposits meet minimum requirements
    (asserts! (>= deposit1 (var-get min-channel-deposit)) err-invalid-amount)
    
    ;; Ensure participant1 has sufficient funds
    (asserts! (<= deposit1 (stx-get-balance participant1)) err-insufficient-funds)
    
    ;; Check if channel already exists
    (asserts! (is-none (map-get? participant-channels { 
      participant1: participant1, 
      participant2: participant2 
    })) err-channel-exists)
    
    ;; Check if both participants are registered
    (asserts! (is-some (map-get? participants { participant: participant1 })) err-not-registered)
    (asserts! (is-some (map-get? participants { participant: participant2 })) err-not-registered)
    
    ;; Transfer funds from participant1 to contract
    (try! (stx-transfer? deposit1 participant1 (as-contract tx-sender)))
    
    ;; Create channel entry
    (map-set channels
      { channel-id: channel-id }
      {
        participant1: participant1,
        participant2: participant2,
        capacity: deposit1,  ;; Initial capacity is just deposit1 (deposit2 added later)
        participant1-balance: deposit1,
        participant2-balance: u0,     ;; participant2 will deposit later
        participant1-nonce: u0,
        participant2-nonce: u0,
        open-block: block-height,
        state: u0,           ;; 0 = Open
        closing-initiated: none,
        closing-initiator: none,
        settle-block: none
      }
    )
    
    ;; Create bi-directional lookup
    (map-set participant-channels
      { participant1: participant1, participant2: participant2 }
      { channel-id: channel-id }
    )
    (map-set participant-channels
      { participant1: participant2, participant2: participant1 }
      { channel-id: channel-id }
    )
    
    ;; Update participants' metrics
    (update-participant-metrics participant1 true deposit1)
    
    ;; Update routing table
    (map-set routing-edges
      { from: participant1, to: participant2 }
      {
        channel-id: channel-id,
        capacity: deposit1,
        fee-rate: u10,  ;; Default fee rate (0.1%)
        last-updated: block-height
      }
    )
    
    ;; Increment channel ID
    (var-set next-channel-id (+ channel-id u1))
    
    (ok channel-id)
  )
)

;; Join an existing channel and deposit funds
(define-public (join-channel (channel-id uint) (deposit uint))
  (let (
    (participant tx-sender)
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
  )
    ;; Ensure channel is in open state
    (asserts! (is-eq (get state channel) u0) err-channel-closed)
    
    ;; Ensure participant is the intended second participant
    (asserts! (is-eq participant (get participant2 channel)) err-not-authorized)
    
    ;; Ensure participant2 hasn't already deposited
    (asserts! (is-eq (get participant2-balance channel) u0) err-invalid-state)
    
    ;; Ensure deposit meets minimum requirements
    (asserts! (>= deposit (var-get min-channel-deposit)) err-invalid-amount)
    
    ;; Ensure participant has sufficient funds
    (asserts! (<= deposit (stx-get-balance participant)) err-insufficient-funds)
    
    ;; Transfer funds from participant to contract
    (try! (stx-transfer? deposit participant (as-contract tx-sender)))
    
    ;; Update channel
    (map-set channels
      { channel-id: channel-id }
      (merge channel {
        capacity: (+ (get capacity channel) deposit),
        participant2-balance: deposit
      })
    )
    
    ;; Update participant metrics
    (update-participant-metrics participant true deposit)
    
    ;; Update routing in other direction
    (map-set routing-edges
      { from: participant, to: (get participant1 channel) }
      {
        channel-id: channel-id,
        capacity: deposit,
        fee-rate: u10,  ;; Default fee rate (0.1%)
        last-updated: block-height
      }
    )
    
    (ok true)
  )
)

;; Helper function to update participant metrics
(define-private (update-participant-metrics (participant principal) (is-increase bool) (amount uint))
  (let (
    (participant-data (unwrap-panic (map-get? participants { participant: participant })))
    (current-channels (get total-channels participant-data))
    (current-capacity (get total-capacity participant-data))
  )
    (map-set participants
      { participant: participant }
      (merge participant-data {
        total-channels: (if is-increase (+ current-channels u1) (- current-channels u1)),
        total-capacity: (if is-increase 
                          (+ current-capacity amount) 
                          (if (> current-capacity amount) (- current-capacity amount) u0)),
        last-active: block-height
      })
    )
  )
)

;; Submit a balance proof (for off-chain state updates)
(define-public (submit-balance-proof
  (channel-id uint)
  (balance uint)
  (nonce uint)
  (signature (buff 65)))
  
  (let (
    (submitter tx-sender)
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
    (participant1 (get participant1 channel))
    (participant2 (get participant2 channel))
    (is-participant1 (is-eq submitter participant1))
    (is-participant2 (is-eq submitter participant2))
  )
    ;; Ensure submitter is a channel participant
    (asserts! (or is-participant1 is-participant2) err-not-authorized)
    
    ;; Ensure channel is open
    (asserts! (is-eq (get state channel) u0) err-channel-closed)
    
    ;; Determine which participant is submitting the balance proof
    (let (
      (counterparty (if is-participant1 participant2 participant1))
      (current-nonce (if is-participant1 (get participant2-nonce channel) (get participant1-nonce channel)))
    )
      ;; Ensure nonce is higher than current
      (asserts! (> nonce current-nonce) err-invalid-balance-proof)
      
      ;; Ensure balance is not more than channel capacity
      (asserts! (<= balance (get capacity channel)) err-invalid-amount)
      
      ;; Validate signature (in practice, would verify the counterparty's signature here)
      ;; For simplicity, we're skipping actual signature verification in this example
      
      ;; Store the balance proof
      (map-set balance-proofs
        { channel-id: channel-id, participant: counterparty }
        {
          nonce: nonce,
          balance: balance,
          signature: signature
        }
      )
      
      ;; Update channel state
      (map-set channels
        { channel-id: channel-id }
        (merge channel 
          (if is-participant1
            { participant2-nonce: nonce }
            { participant1-nonce: nonce }
          )
        )
      )
      
      (ok true)
    )
  )
)

;; Initiate cooperative channel close (both parties agree)
(define-public (cooperative-close-channel 
  (channel-id uint)
  (balance1 uint)
  (balance2 uint)
  (signature1 (buff 65))
  (signature2 (buff 65)))
  
  (let (
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
    (participant1 (get participant1 channel))
    (participant2 (get participant2 channel))
    (capacity (get capacity channel))
  )
    ;; Ensure channel is open
    (asserts! (is-eq (get state channel) u0) err-channel-closed)
    
    ;; Ensure the participant is one of the channel participants
    (asserts! (or (is-eq tx-sender participant1) (is-eq tx-sender participant2)) err-not-authorized)
    
    ;; Ensure sum of balances equals channel capacity
    (asserts! (is-eq (+ balance1 balance2) capacity) err-invalid-amount)
    
    ;; Validate signatures (in practice, would verify both signatures here)
    ;; For simplicity, we're skipping actual signature verification in this example
    
    ;; Transfer balances to participants
    (as-contract (try! (stx-transfer? balance1 (as-contract tx-sender) participant1)))
    (as-contract (try! (stx-transfer? balance2 (as-contract tx-sender) participant2)))
    
    ;; Update channel state
    (map-set channels
      { channel-id: channel-id }
      (merge channel {
        state: u2,  ;; Settled
        participant1-balance: u0,
        participant2-balance: u0,
        capacity: u0,
        settle-block: (some block-height)
      })
    )
    
    ;; Update participant metrics
    (update-participant-metrics participant1 false balance1)
    (update-participant-metrics participant2 false balance2)
    
    ;; Remove from routing table
    (map-delete routing-edges { from: participant1, to: participant2 })
    (map-delete routing-edges { from: participant2, to: participant1 })
    
    (ok { participant1-balance: balance1, participant2-balance: balance2 })
  )
)

;; Initiate non-cooperative channel close (unilateral)
(define-public (initiate-channel-close (channel-id uint))
  (let (
    (participant tx-sender)
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
    (participant1 (get participant1 channel))
    (participant2 (get participant2 channel))
  )
    ;; Ensure channel is open
    (asserts! (is-eq (get state channel) u0) err-channel-closed)
    
    ;; Ensure the initiator is one of the channel participants
    (asserts! (or (is-eq participant participant1) (is-eq participant participant2)) err-not-authorized)
    
    ;; Set channel state to closing (1)
    (map-set channels
      { channel-id: channel-id }
      (merge channel {
        state: u1,  ;; Closing
        closing-initiated: (some block-height),
        closing-initiator: (some participant),
        settle-block: (some (+ block-height (var-get dispute-timeout)))
      })
    )
    
    (ok { dispute-end-block: (+ block-height (var-get dispute-timeout)) })
  )
)