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
;; Update channel during dispute period
(define-public (update-channel-in-dispute 
  (channel-id uint)
  (balance uint)
  (nonce uint)
  (signature (buff 65)))
  
  (let (
    (participant tx-sender)
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
    (participant1 (get participant1 channel))
    (participant2 (get participant2 channel))
    (is-participant1 (is-eq participant participant1))
    (is-participant2 (is-eq participant participant2))
    (settle-block (unwrap! (get settle-block channel) err-invalid-state))
  )
    ;; Ensure channel is in closing state
    (asserts! (is-eq (get state channel) u1) err-invalid-state)
    
    ;; Ensure participant is authorized
    (asserts! (or is-participant1 is-participant2) err-not-authorized)
    
    ;; Ensure dispute period hasn't ended
    (asserts! (< block-height settle-block) err-timelock-not-expired)
    
    ;; Get counterparty and nonce
    (let (
      (counterparty (if is-participant1 participant2 participant1))
      (current-nonce (if is-participant1 (get participant2-nonce channel) (get participant1-nonce channel)))
    )
      ;; Ensure nonce is higher than current
      (asserts! (> nonce current-nonce) err-invalid-balance-proof)
      
      ;; Validate signature
      ;; For simplicity, actual signature verification is skipped
      
      ;; Update balance proofs
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

;; Settle channel after dispute period
(define-public (settle-channel (channel-id uint))
  (let (
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
    (participant1 (get participant1 channel))
    (participant2 (get participant2 channel))
    (capacity (get capacity channel))
    (settle-block (unwrap! (get settle-block channel) err-invalid-state))
  )
    ;; Ensure channel is in closing state
    (asserts! (is-eq (get state channel) u1) err-invalid-state)
    
    ;; Ensure dispute period has ended
    (asserts! (>= block-height settle-block) err-timelock-not-expired)
    
    ;; Get final balances from most recent balance proofs
    (let (
      (proof1 (map-get? balance-proofs { channel-id: channel-id, participant: participant1 }))
      (proof2 (map-get? balance-proofs { channel-id: channel-id, participant: participant2 }))
      (balance1 (if (is-some proof1) (get balance (unwrap-panic proof1)) (get participant1-balance channel)))
      (balance2 (if (is-some proof2) (get balance (unwrap-panic proof2)) (get participant2-balance channel)))
      (adjusted-balance1 (if (> (+ balance1 balance2) capacity) 
                           (* balance1 (/ capacity (+ balance1 balance2)))
                           balance1))
      (adjusted-balance2 (- capacity adjusted-balance1))
    )
      ;; Transfer balances to participants
      (as-contract (try! (stx-transfer? adjusted-balance1 (as-contract tx-sender) participant1)))
      (as-contract (try! (stx-transfer? adjusted-balance2 (as-contract tx-sender) participant2)))
      
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
      (update-participant-metrics participant1 false adjusted-balance1)
      (update-participant-metrics participant2 false adjusted-balance2)
      
      ;; Remove from routing table
      (map-delete routing-edges { from: participant1, to: participant2 })
      (map-delete routing-edges { from: participant2, to: participant1 })
      
      (ok { 
        participant1-balance: adjusted-balance1, 
        participant2-balance: adjusted-balance2 
      })
    )
  )
)

;; Create a Hashed Time-Locked Contract (HTLC) for multi-hop payments
(define-public (create-htlc 
  (channel-id uint)
  (receiver principal)
  (amount uint)
  (hashlock (buff 32))
  (timelock uint))
  
  (let (
    (sender tx-sender)
    (htlc-id (var-get next-htlc-id))
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
    (participant1 (get participant1 channel))
    (participant2 (get participant2 channel))
    (is-participant1 (is-eq sender participant1))
    (is-participant2 (is-eq sender participant2))
  )
    ;; Ensure channel is open
    (asserts! (is-eq (get state channel) u0) err-channel-closed)
    
    ;; Ensure sender is a channel participant
    (asserts! (or is-participant1 is-participant2) err-not-authorized)
    
    ;; Ensure receiver is the other channel participant
    (asserts! (if is-participant1 
               (is-eq receiver participant2)
               (is-eq receiver participant1)) 
             err-not-authorized)
    
    ;; Ensure sender has sufficient funds
    (asserts! (if is-participant1
               (>= (get participant1-balance channel) amount)
               (>= (get participant2-balance channel) amount))
             err-insufficient-funds)
    
    ;; Ensure timelock is reasonable
    (asserts! (> timelock block-height) err-invalid-parameters)
    
    ;; Create HTLC
    (map-set htlcs
      { htlc-id: htlc-id }
      {
        channel-id: channel-id,
        sender: sender,
        receiver: receiver,
        amount: amount,
        hashlock: hashlock,
        timelock: timelock,
        preimage: none,
        claimed: false,
        refunded: false,
        created-at: block-height
      }
    )
    
    ;; Update sender balance (lock the funds)
    (map-set channels
      { channel-id: channel-id }
      (merge channel 
        (if is-participant1
          { participant1-balance: (- (get participant1-balance channel) amount) }
          { participant2-balance: (- (get participant2-balance channel) amount) }
        )
      )
    )
    
    ;; Increment HTLC ID
    (var-set next-htlc-id (+ htlc-id u1))
    
    (ok htlc-id)
  )
)

;; Fulfill an HTLC with a preimage
(define-public (fulfill-htlc (htlc-id uint) (preimage (buff 32)))
  (let (
    (receiver tx-sender)
    (htlc (unwrap! (map-get? htlcs { htlc-id: htlc-id }) err-htlc-expired))
    (channel-id (get channel-id htlc))
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
  )
    ;; Ensure HTLC hasn't been claimed or refunded
    (asserts! (not (get claimed htlc)) err-invalid-state)
    (asserts! (not (get refunded htlc)) err-invalid-state)
    
    ;; Ensure timelock hasn't expired
    (asserts! (< block-height (get timelock htlc)) err-htlc-expired)
    
    ;; Ensure receiver is claiming
    (asserts! (is-eq receiver (get receiver htlc)) err-not-authorized)
    
    ;; Verify preimage hashes to hashlock
    (asserts! (is-eq (sha256 preimage) (get hashlock htlc)) err-incorrect-preimage)
    
    ;; Credit receiver
    (let (
      (amount (get amount htlc))
      (participant1 (get participant1 channel))
      (participant2 (get participant2 channel))
      (is-receiver-participant1 (is-eq receiver participant1))
    )
      ;; Update receiver balance
      (map-set channels
        { channel-id: channel-id }
        (merge channel 
          (if is-receiver-participant1
            { participant1-balance: (+ (get participant1-balance channel) amount) }
            { participant2-balance: (+ (get participant2-balance channel) amount) }
          )
        )
      )
      
      ;; Update HTLC
      (map-set htlcs
        { htlc-id: htlc-id }
        (merge htlc {
          preimage: (some preimage),
          claimed: true
        })
      )
      
      (ok true)
    )
  )
)

;; Refund expired HTLC
(define-public (refund-htlc (htlc-id uint))
  (let (
    (sender tx-sender)
    (htlc (unwrap! (map-get? htlcs { htlc-id: htlc-id }) err-htlc-expired))
    (channel-id (get channel-id htlc))
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
  )
    ;; Ensure HTLC hasn't been claimed or refunded
    (asserts! (not (get claimed htlc)) err-invalid-state)
    (asserts! (not (get refunded htlc)) err-invalid-state)
    
    ;; Ensure timelock has expired
    (asserts! (>= block-height (get timelock htlc)) err-timelock-not-expired)
    
    ;; Ensure sender is requesting refund
    (asserts! (is-eq sender (get sender htlc)) err-not-authorized)
    
    ;; Refund sender
    (let (
      (amount (get amount htlc))
      (participant1 (get participant1 channel))
      (participant2 (get participant2 channel))
      (is-sender-participant1 (is-eq sender participant1))
    )
      ;; Update sender balance
      (map-set channels
        { channel-id: channel-id }
        (merge channel 
          (if is-sender-participant1
            { participant1-balance: (+ (get participant1-balance channel) amount) }
            { participant2-balance: (+ (get participant2-balance channel) amount) }
          )
        )
      )
      
      ;; Update HTLC
      (map-set htlcs
        { htlc-id: htlc-id }
        (merge htlc { refunded: true })
      )
      
      (ok true)
    )
  )
)

;; Add funds to an existing channel
(define-public (add-funds (channel-id uint) (amount uint))
  (let (
    (participant tx-sender)
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
    (participant1 (get participant1 channel))
    (participant2 (get participant2 channel))
    (is-participant1 (is-eq participant participant1))
    (is-participant2 (is-eq participant participant2))
  )
    ;; Ensure channel is open
    (asserts! (is-eq (get state channel) u0) err-channel-closed)
    
    ;; Ensure participant is authorized
    (asserts! (or is-participant1 is-participant2) err-not-authorized)
    
    ;; Ensure amount is reasonable
    (asserts! (> amount u0) err-invalid-amount)
    
    ;; Transfer funds
    (try! (stx-transfer? amount participant (as-contract tx-sender)))
    
    ;; Update channel
    (map-set channels
      { channel-id: channel-id }
      (merge channel {
        capacity: (+ (get capacity channel) amount),
        participant1-balance: (+ (get participant1-balance channel) (if is-participant1 amount u0)),
        participant2-balance: (+ (get participant2-balance channel) (if is-participant2 amount u0))
      })
    )
    
    ;; Update participant metrics
    (update-participant-metrics participant true amount)
    
        ;; Update routing edges
    (if is-participant1
      (map-set routing-edges
        { from: participant1, to: participant2 }
        (merge 
          (unwrap-panic (map-get? routing-edges { from: participant1, to: participant2 }))
          { 
            capacity: (+ (get capacity channel) amount),
            last-updated: block-height
          }
        )
      )
      (map-set routing-edges
        { from: participant2, to: participant1 }
        (merge 
          (unwrap-panic (map-get? routing-edges { from: participant2, to: participant1 }))
          { 
            capacity: (+ (get capacity channel) amount),
            last-updated: block-height
          }
        )
      )
    )
    
    (ok true)
  )
)

;; Find a payment route (simplified version, in practice would use a more complex routing algorithm)
(define-public (find-payment-route (sender principal) (receiver principal) (amount uint))
  (let (
    (direct-channel (map-get? participant-channels { participant1: sender, participant2: receiver }))
  )
    (if (is-some direct-channel)
      ;; Direct channel exists, check capacity
      (let (
        (channel-id (get channel-id (unwrap-panic direct-channel)))
        (channel (unwrap-panic (map-get? channels { channel-id: channel-id })))
        (sender-balance (if (is-eq sender (get participant1 channel))
                           (get participant1-balance channel)
                           (get participant2-balance channel)))
      )
        (if (>= sender-balance amount)
          (ok (list channel-id)) ;; Direct route available
          (err err-insufficient-funds)
        )
      )
      ;; Need to find an indirect route (only 1-hop for simplicity)
      (find-indirect-route sender receiver amount)
    )
  )
)

;; Helper to find indirect routes via intermediaries
(define-private (find-indirect-route (sender principal) (receiver principal) (amount uint))
  (let (
    (participants (var-get network-participants))
    (potential-routes (filter-potential-intermediaries participants sender receiver amount))
  )
    (if (> (len potential-routes) u0)
      (ok (unwrap-panic (element-at potential-routes u0)))
      (err err-route-not-found)
    )
  )
)

;; Helper to filter potential intermediaries for routing
(define-private (filter-potential-intermediaries 
  (participants (list 1000 principal))
  (sender principal)
  (receiver principal)
  (amount uint))
  
  (let (
    (intermediaries (filter-out-endpoints participants sender receiver))
    (viable-routes (map-find-route intermediaries sender receiver amount (list)))
  )
    viable-routes
  )
)

;; Filter out endpoints from participant list
(define-private (filter-out-endpoints (participants (list 1000 principal)) (sender principal) (receiver principal))
  (filter 
    (lambda (participant) 
      (and 
        (not (is-eq participant sender)) 
        (not (is-eq participant receiver))
      )
    ) 
    participants
  )
)

;; Find a route through a specific intermediary
(define-private (map-find-route 
  (intermediaries (list 1000 principal))
  (sender principal)
  (receiver principal)
  (amount uint)
  (acc (list 1000 (list 2 uint))))
  
  (foldr check-intermediary acc intermediaries sender receiver amount)
)

;; Check if an intermediary can route the payment
(define-private (check-intermediary 
  (intermediary principal) 
  (acc (list 1000 (list 2 uint)))
  (sender principal)
  (receiver principal)
  (amount uint))
  
  (let (
    (channel1 (map-get? participant-channels { participant1: sender, participant2: intermediary }))
    (channel2 (map-get? participant-channels { participant1: intermediary, participant2: receiver }))
  )
    (if (and (is-some channel1) (is-some channel2))
      (let (
        (channel1-id (get channel-id (unwrap-panic channel1)))
        (channel2-id (get channel-id (unwrap-panic channel2)))
        (channel1-data (unwrap-panic (map-get? channels { channel-id: channel1-id })))
        (channel2-data (unwrap-panic (map-get? channels { channel-id: channel2-id })))
        (sender-balance (if (is-eq sender (get participant1 channel1-data))
                           (get participant1-balance channel1-data)
                           (get participant2-balance channel1-data)))
        (intermediary-balance (if (is-eq intermediary (get participant1 channel2-data))
                                 (get participant1-balance channel2-data)
                                 (get participant2-balance channel2-data)))
      )
        (if (and (>= sender-balance amount) (>= intermediary-balance amount))
          (append acc (list channel1-id channel2-id))
          acc
        )
      )
      acc
    )
  )
)

;; Start a multi-hop payment
(define-public (start-multi-hop-payment 
  (receiver principal)
  (amount uint)
  (route (list 10 uint))
  (secret (buff 32)))
  
  (let (
    (sender tx-sender)
    (hashlock (sha256 secret))
    (timelock (+ block-height u144)) ;; 1 day timelock
    (route-length (len route))
  )
    ;; Ensure route is valid
    (asserts! (> route-length u0) err-invalid-route)
    
    ;; For a 2-hop route (through 1 intermediary), we should have 2 channels
    (if (is-eq route-length u2)
      ;; Route through an intermediary
      (let (
        (channel1-id (unwrap-panic (element-at route u0)))
        (channel2-id (unwrap-panic (element-at route u1)))
        (channel1 (unwrap! (map-get? channels { channel-id: channel1-id }) err-channel-not-found))
        (channel2 (unwrap! (map-get? channels { channel-id: channel2-id }) err-channel-not-found))
        (intermediary (find-intermediary channel1 channel2 sender receiver))
      )
        ;; Ensure intermediary exists
        (asserts! (is-some intermediary) err-invalid-route)
        
        ;; Create first HTLC (sender -> intermediary)
        (try! (create-htlc channel1-id (unwrap-panic intermediary) amount hashlock timelock))
        
        ;; Return hashlock for continuation
        (ok { 
          hashlock: hashlock, 
          timelock: timelock, 
          intermediary: (unwrap-panic intermediary),
          first-htlc: (- (var-get next-htlc-id) u1)
        })
      )
      ;; Direct route (single channel)
      (let (
        (channel-id (unwrap-panic (element-at route u0)))
        (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
      )
        ;; Ensure this is a direct channel between sender and receiver
        (asserts! (or 
                   (and (is-eq sender (get participant1 channel)) (is-eq receiver (get participant2 channel)))
                   (and (is-eq sender (get participant2 channel)) (is-eq receiver (get participant1 channel)))
                  ) 
                  err-invalid-route)
        
        ;; Create HTLC
        (try! (create-htlc channel-id receiver amount hashlock timelock))
        
        (ok {
          hashlock: hashlock, 
          timelock: timelock,
          first-htlc: (- (var-get next-htlc-id) u1)
        })
      )
    )
  )
)

;; Helper to find the intermediary in a 2-hop route
(define-private (find-intermediary (channel1 (tuple participant1: principal participant2: principal ...)) 
                                  (channel2 (tuple participant1: principal participant2: principal ...))
                                  (sender principal)
                                  (receiver principal))
  (let (
    (p1-ch1 (get participant1 channel1))
    (p2-ch1 (get participant2 channel1))
    (p1-ch2 (get participant1 channel2))
    (p2-ch2 (get participant2 channel2))
  )
    (cond
      ;; Sender is p1 in ch1, receiver is p2 in ch2
      ((and (is-eq sender p1-ch1) (is-eq receiver p2-ch2) (is-eq p2-ch1 p1-ch2))
       (some p2-ch1))
      ;; Sender is p1 in ch1, receiver is p1 in ch2
      ((and (is-eq sender p1-ch1) (is-eq receiver p1-ch2) (is-eq p2-ch1 p2-ch2))
       (some p2-ch1))
      ;; Sender is p2 in ch1, receiver is p2 in ch2
      ((and (is-eq sender p2-ch1) (is-eq receiver p2-ch2) (is-eq p1-ch1 p1-ch2))
       (some p1-ch1))
      ;; Sender is p2 in ch1, receiver is p1 in ch2
      ((and (is-eq sender p2-ch1) (is-eq receiver p1-ch2) (is-eq p1-ch1 p2-ch2))
       (some p1-ch1))
      (else none)
    )
  )
)
;; Continue multi-hop payment as an intermediary
(define-public (continue-multi-hop-payment
  (prev-channel-id uint)
  (next-channel-id uint)
  (receiver principal)
  (amount uint)
  (hashlock (buff 32))
  (timelock uint))
  
  (let (
    (intermediary tx-sender)
    ;; Next hop needs a shorter timelock to ensure intermediary can claim before committing
    (next-timelock (- timelock u12)) ;; ~2 hours less
  )
    ;; Verify next timelock is still in the future
    (asserts! (> next-timelock block-height) err-invalid-parameters)
    
    ;; Create HTLC for the next hop
    (try! (create-htlc next-channel-id receiver amount hashlock next-timelock))
    
    (ok (- (var-get next-htlc-id) u1)) ;; Return the HTLC ID just created
  )
)

;; Complete multi-hop payment with preimage
(define-public (complete-multi-hop-payment
  (htlc-id uint)
  (preimage (buff 32)))
  
  (let (
    (receiver tx-sender)
  )
    ;; Fulfill the HTLC with the preimage
    (try! (fulfill-htlc htlc-id preimage))
    
    (ok { preimage: preimage })
  )
)

;; Automatically rebalance channels
(define-public (rebalance-channels (channel1-id uint) (channel2-id uint) (amount uint))
  (let (
    (participant tx-sender)
    (channel1 (unwrap! (map-get? channels { channel-id: channel1-id }) err-channel-not-found))
    (channel2 (unwrap! (map-get? channels { channel-id: channel2-id }) err-channel-not-found))
    ;; Determine if participant is in both channels
    (participant-in-channel1 (or (is-eq participant (get participant1 channel1)) 
                                (is-eq participant (get participant2 channel1))))
    (participant-in-channel2 (or (is-eq participant (get participant1 channel2)) 
                                (is-eq participant (get participant2 channel2))))
  )
    ;; Ensure participant is in both channels
    (asserts! (and participant-in-channel1 participant-in-channel2) err-not-authorized)
    
    ;; Ensure channels are open
    (asserts! (is-eq (get state channel1) u0) err-channel-closed)
    (asserts! (is-eq (get state channel2) u0) err-channel-closed)
    
    ;; Find participant's balance in channel1
    (let (
      (balance-in-channel1 (if (is-eq participant (get participant1 channel1))
                              (get participant1-balance channel1)
                              (get participant2-balance channel1)))
      (balance-in-channel2 (if (is-eq participant (get participant1 channel2))
                              (get participant1-balance channel2)
                              (get participant2-balance channel2)))
    )
      ;; Ensure sufficient balance in channel1
      (asserts! (>= balance-in-channel1 amount) err-insufficient-funds)
      
      ;; Find counterparties in each channel
      (let (
        (counterparty1 (if (is-eq participant (get participant1 channel1))
                          (get participant2 channel1)
                          (get participant1 channel1)))
        (counterparty2 (if (is-eq participant (get participant1 channel2))
                          (get participant2 channel2)
                          (get participant1 channel2)))
      )
        ;; Ensure the channels form a cycle (counterparty1 and counterparty2 must be the same or have a channel)
        (asserts! (or (is-eq counterparty1 counterparty2)
                      (is-some (map-get? participant-channels { 
                                 participant1: counterparty1, 
                                 participant2: counterparty2 
                               })))
                  err-invalid-route)
        
        ;; Update channel1 - decrease participant's balance
        (map-set channels
          { channel-id: channel1-id }
          (merge channel1 
            (if (is-eq participant (get participant1 channel1))
              { participant1-balance: (- balance-in-channel1 amount) }
              { participant2-balance: (- balance-in-channel1 amount) }
            )
          )
        )
        
        ;; Update channel2 - increase participant's balance
        (map-set channels
          { channel-id: channel2-id }
          (merge channel2 
            (if (is-eq participant (get participant1 channel2))
              { participant1-balance: (+ balance-in-channel2 amount) }
              { participant2-balance: (+ balance-in-channel2 amount) }
            )
          )
        )
        
        ;; Update routing edges
        (update-routing-edges channel1-id channel2-id participant counterparty1 counterparty2 amount)
        
        (ok { rebalanced: amount })
      )
    )
  )
)

;; Helper to update routing edges after rebalancing
(define-private (update-routing-edges 
  (channel1-id uint) 
  (channel2-id uint)
  (participant principal)
  (counterparty1 principal)
  (counterparty2 principal)
  (amount uint))
  
  (let (
    (edge1 (unwrap-panic (map-get? routing-edges { from: participant, to: counterparty1 })))
    (edge2 (unwrap-panic (map-get? routing-edges { from: participant, to: counterparty2 })))
  )
    ;; Update capacity for edge1 (decreasing)
    (map-set routing-edges
      { from: participant, to: counterparty1 }
      (merge edge1 { 
        capacity: (- (get capacity edge1) amount),
        last-updated: block-height
      })
    )
    
    ;; Update capacity for edge2 (increasing)
    (map-set routing-edges
      { from: participant, to: counterparty2 }
      (merge edge2 { 
        capacity: (+ (get capacity edge2) amount),
        last-updated: block-height
      })
    )
    
    true
  )
)

;; Update fee rate for routing
(define-public (set-fee-rate (channel-id uint) (fee-rate uint))
  (let (
    (participant tx-sender)
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) err-channel-not-found))
    (participant1 (get participant1 channel))
    (participant2 (get participant2 channel))
    (counterparty (if (is-eq participant participant1) participant2 participant1))
  )
    ;; Ensure participant is in channel
    (asserts! (or (is-eq participant participant1) (is-eq participant participant2)) err-not-authorized)
    
    ;; Ensure channel is open
    (asserts! (is-eq (get state channel) u0) err-channel-closed)
    
    ;; Ensure fee rate is reasonable
    (asserts! (<= fee-rate u1000) err-invalid-parameters) ;; Max 10%
    
    ;; Update routing edge
    (map-set routing-edges
      { from: participant, to: counterparty }
      (merge 
        (unwrap-panic (map-get? routing-edges { from: participant, to: counterparty }))
        { 
          fee-rate: fee-rate,
          last-updated: block-height
        }
      )
    )
    
    (ok true)
  )
)

;; Calculate fee for a payment
(define-read-only (calculate-fee (amount uint) (fee-rate uint))
  (/ (* amount fee-rate) u10000)
)

;; Get channel information
(define-read-only (get-channel-info (channel-id uint))
  (map-get? channels { channel-id: channel-id })
)

;; Get participant information
(define-read-only (get-participant-info (participant principal))
  (map-get? participants { participant: participant })
)

;; Get HTLC information
(define-read-only (get-htlc-info (htlc-id uint))
  (map-get? htlcs { htlc-id: htlc-id })
)

;; Get list of all participant's channels
(define-read-only (get-participant-channel-list (participant principal))
  (filter-participant-channels (var-get network-participants) participant (list))
)

;; Helper to filter channels by participant
(define-private (filter-participant-channels 
  (all-participants (list 1000 principal))
  (target-participant principal)
  (acc (list 1000 uint)))
  
  (fold check-channel-with-participant acc all-participants target-participant)
)

;; Check if a channel exists between two participants
(define-private (check-channel-with-participant 
  (other-participant principal)
  (acc (list 1000 uint))
  (target-participant principal))
  
  (if (is-eq other-participant target-participant)
    acc
    (let (
      (channel-id-tuple (map-get? participant-channels { 
                         participant1: target-participant, 
                         participant2: other-participant 
                       }))
    )
      (if (is-some channel-id-tuple)
        (append acc (get channel-id (unwrap-panic channel-id-tuple)))
        acc
      )
    )
  )
)

;; Get channel status as string
(define-read-only (get-channel-status (channel-id uint))
  (let (
    (channel (map-get? channels { channel-id: channel-id }))
  )
    (if (is-some channel)
      (let (
        (state (get state (unwrap-panic channel)))
        (channel-states-list (var-get channel-states))
      )
        (default-to "Unknown" (element-at channel-states-list state))
      )
      "Not Found"
    )
  )
)

;; Get network statistics
(define-read-only (get-network-stats)
  {
    total-channels: (- (var-get next-channel-id) u1),
    total-participants: (len (var-get network-participants)),
    protocol-fee: (var-get protocol-fee-percentage),
    min-deposit: (var-get min-channel-deposit)
  }
)

;; Check if a route exists between two participants
(define-read-only (route-exists (sender principal) (receiver principal))
  (is-some (map-get? participant-channels { participant1: sender, participant2: receiver }))
)

