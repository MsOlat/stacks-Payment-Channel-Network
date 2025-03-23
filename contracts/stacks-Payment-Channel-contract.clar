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