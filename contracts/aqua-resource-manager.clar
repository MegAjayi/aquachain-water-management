;; aqua-resource-manager
;; 
;; This contract serves as the central hub for AquaChain's water management system.
;; It manages water resource allocation, rights, and usage tracking on the Stacks blockchain.
;; The contract enables registration of water sources, allocation of water rights,
;; tracking of consumption, and enforcement of usage policies in a transparent,
;; equitable, and accountable manner.

;; =====================================
;; Error codes
;; =====================================
(define-constant ERR-UNAUTHORIZED u1001)
(define-constant ERR-SOURCE-EXISTS u1002)
(define-constant ERR-SOURCE-NOT-FOUND u1003)
(define-constant ERR-USER-NOT-REGISTERED u1004)
(define-constant ERR-INSUFFICIENT-RIGHTS u1005)
(define-constant ERR-EXCEEDS-ALLOCATION u1006)
(define-constant ERR-TRANSFER-FAILED u1007)
(define-constant ERR-INVALID-AMOUNT u1008)
(define-constant ERR-DROUGHT-EMERGENCY u1009)
(define-constant ERR-ALREADY-REGISTERED u1010)
(define-constant ERR-INVALID-SEASON u1011)
(define-constant ERR-POLICY-LOCKED u1012)

;; =====================================
;; Data maps and vars
;; =====================================

;; Contract administrator
(define-data-var contract-admin principal tx-sender)

;; Drought emergency status
(define-data-var drought-emergency bool false)

;; Policy lock period (in blocks)
(define-data-var policy-lock-height uint u0)
(define-data-var policy-lock-duration uint u50) ;; Approximately 8.5 hours at 10 min/block

;; Water sources map: stores details about each registered water source
(define-map water-sources 
  { source-id: uint }
  {
    name: (string-ascii 50),
    location: (string-ascii 100),
    total-capacity: uint,  ;; in cubic meters
    current-level: uint,   ;; in cubic meters
    last-updated: uint     ;; block height when last updated
  }
)

;; Current highest source ID for auto-incrementing
(define-data-var next-source-id uint u1)

;; User water rights map: stores water allocation rights for each user
(define-map user-rights 
  { user: principal }
  {
    allocation-base: uint,        ;; Base allocation in cubic meters
    allocation-used: uint,        ;; Amount used in current period
    last-reset: uint,             ;; Block height when last reset
    registered-at: uint,          ;; Block height when user registered
    authorized-sources: (list 10 uint)  ;; Source IDs user can draw from
  }
)

;; Seasonal allocation adjustments
(define-map seasonal-adjustments
  { season: uint }  ;; 1=Spring, 2=Summer, 3=Fall, 4=Winter
  { 
    multiplier: uint  ;; Base allocation multiplier (in basis points, e.g., 10000 = 100%)
  }
)

;; Water usage history records all consumption transactions
(define-map water-usage-history
  { transaction-id: uint }
  {
    user: principal,
    source-id: uint,
    amount: uint,
    timestamp: uint,
    season: uint
  }
)
(define-data-var next-transaction-id uint u1)

;; =====================================
;; Private functions
;; =====================================

;; Helper to check if caller is the contract administrator
(define-private (is-admin)
  (is-eq tx-sender (var-get contract-admin))
)

;; Helper to calculate current season based on block height
;; Each "year" is approximately 52560 blocks (365 days * 144 blocks/day)
;; Each "season" is approximately 13140 blocks (91 days * 144 blocks/day)
(define-private (get-current-season)
  (let
    (
      (blocks-per-year u52560)
      (current-block block-height)
      (year-position (mod current-block blocks-per-year))
      (season-length (/ blocks-per-year u4))
    )
    (+ u1 (/ year-position season-length))
  )
)

;; Get seasonal adjustment for current season
(define-private (get-seasonal-multiplier)
  (let 
    (
      (current-season (get-current-season))
      (season-data (default-to { multiplier: u10000 } (map-get? seasonal-adjustments { season: current-season })))
    )
    (get multiplier season-data)
  )
)

;; Calculate adjusted allocation based on season
(define-private (calculate-allocation (base-allocation uint))
  (let
    (
      (seasonal-multiplier (get-seasonal-multiplier))
    )
    (/ (* base-allocation seasonal-multiplier) u10000)
  )
)

;; Check if user has sufficient water rights for requested amount
(define-private (has-sufficient-rights (user principal) (amount uint))
  (let
    (
      (user-data (unwrap! (map-get? user-rights { user: user }) false))
      (base-allocation (get allocation-base user-data))
      (used-allocation (get allocation-used user-data))
      (adjusted-allocation (calculate-allocation base-allocation))
    )
    (and
      ;; Check if user has not exceeded their allocation
      (<= (+ used-allocation amount) adjusted-allocation)
      ;; Check if there's no drought emergency
      (not (var-get drought-emergency))
    )
  )
)

;; Update source water level
(define-private (update-source-level (source-id uint) (amount-change int))
  (let
    (
      (source (unwrap! (map-get? water-sources { source-id: source-id }) false))
      (current-level (get current-level source))
      (new-level (if (< amount-change i0)
                    ;; Withdrawal: ensure non-negative result
                    (if (>= (to-uint (abs amount-change)) current-level)
                        u0
                        (- current-level (to-uint (abs amount-change))))
                    ;; Deposit: add to current level, capped at total capacity
                    (min (+ current-level (to-uint amount-change)) (get total-capacity source))))
    )
    (map-set water-sources
      { source-id: source-id }
      (merge source {
        current-level: new-level,
        last-updated: block-height
      })
    )
    true
  )
)

;; Record a water usage transaction in history
(define-private (record-usage (user principal) (source-id uint) (amount uint))
  (let
    (
      (tx-id (var-get next-transaction-id))
    )
    (map-set water-usage-history
      { transaction-id: tx-id }
      {
        user: user,
        source-id: source-id,
        amount: amount,
        timestamp: block-height,
        season: (get-current-season)
      }
    )
    (var-set next-transaction-id (+ tx-id u1))
    true
  )
)

;; Update user's used allocation
(define-private (update-user-allocation (user principal) (amount uint))
  (let
    (
      (user-data (unwrap! (map-get? user-rights { user: user }) false))
      (current-used (get allocation-used user-data))
    )
    (map-set user-rights
      { user: user }
      (merge user-data {
        allocation-used: (+ current-used amount)
      })
    )
    true
  )
)

;; Check if a policy update is allowed (not locked)
(define-private (can-update-policy)
  (< (var-get policy-lock-height) block-height)
)

;; =====================================
;; Read-only functions
;; =====================================

;; Get details about a specific water source
(define-read-only (get-source-details (source-id uint))
  (map-get? water-sources { source-id: source-id })
)

;; Get a user's water rights information
(define-read-only (get-user-rights (user principal))
  (map-get? user-rights { user: user })
)

;; Calculate remaining allocation for a user
(define-read-only (get-remaining-allocation (user principal))
  (let
    (
      (user-data (default-to 
                   { allocation-base: u0, allocation-used: u0, last-reset: u0, registered-at: u0, authorized-sources: (list) } 
                   (map-get? user-rights { user: user })))
      (base-allocation (get allocation-base user-data))
      (used-allocation (get allocation-used user-data))
      (adjusted-allocation (calculate-allocation base-allocation))
    )
    {
      total-allocation: adjusted-allocation,
      used-allocation: used-allocation,
      remaining-allocation: (- adjusted-allocation used-allocation)
    }
  )
)

;; Get usage history for a specific user
(define-read-only (get-user-usage-history (user principal) (start-id uint) (count uint))
  (let
    (
      (end-id (- (var-get next-transaction-id) u1))
      (actual-count (min count u50))  ;; Limit to 50 records at a time
    )
    (filter 
      (lambda (entry) 
        (is-eq (get user entry) user))
      (map 
        (lambda (tx-id) 
          (default-to 
            {
              user: user,
              source-id: u0,
              amount: u0,
              timestamp: u0,
              season: u0
            }
            (map-get? water-usage-history { transaction-id: tx-id })))
        (list-range-from start-id actual-count))
    )
  )
)

;; Get current drought emergency status
(define-read-only (get-drought-status)
  (var-get drought-emergency)
)

;; Get current seasonal adjustment
(define-read-only (get-current-adjustment)
  (let
    (
      (current-season (get-current-season))
      (adjustment (default-to { multiplier: u10000 } (map-get? seasonal-adjustments { season: current-season })))
    )
    { 
      season: current-season,
      multiplier: (get multiplier adjustment)
    }
  )
)

;; =====================================
;; Public functions
;; =====================================

;; Register a new water source
(define-public (register-water-source (name (string-ascii 50)) (location (string-ascii 100)) (total-capacity uint))
  (begin
    ;; Check if caller is admin
    (asserts! (is-admin) (err ERR-UNAUTHORIZED))
    
    ;; Check if capacity is valid
    (asserts! (> total-capacity u0) (err ERR-INVALID-AMOUNT))
    
    (let
      (
        (source-id (var-get next-source-id))
      )
      ;; Create new water source
      (map-set water-sources
        { source-id: source-id }
        {
          name: name,
          location: location,
          total-capacity: total-capacity,
          current-level: total-capacity,  ;; Start with full capacity
          last-updated: block-height
        }
      )
      
      ;; Increment the source ID counter
      (var-set next-source-id (+ source-id u1))
      
      (ok source-id)
    )
  )
)

;; Update a water source's current level
(define-public (update-source (source-id uint) (new-level uint))
  (begin
    ;; Check if caller is admin
    (asserts! (is-admin) (err ERR-UNAUTHORIZED))
    
    ;; Check if source exists
    (asserts! (is-some (map-get? water-sources { source-id: source-id })) (err ERR-SOURCE-NOT-FOUND))
    
    (let
      (
        (source (unwrap-panic (map-get? water-sources { source-id: source-id })))
        (total-capacity (get total-capacity source))
      )
      ;; Check that new level does not exceed capacity
      (asserts! (<= new-level total-capacity) (err ERR-INVALID-AMOUNT))
      
      ;; Update the source
      (map-set water-sources
        { source-id: source-id }
        (merge source {
          current-level: new-level,
          last-updated: block-height
        })
      )
      
      (ok true)
    )
  )
)

;; Register a new user with water rights
(define-public (register-user (user principal) (allocation-base uint) (authorized-sources (list 10 uint)))
  (begin
    ;; Check if caller is admin
    (asserts! (is-admin) (err ERR-UNAUTHORIZED))
    
    ;; Check that user is not already registered
    (asserts! (is-none (map-get? user-rights { user: user })) (err ERR-ALREADY-REGISTERED))
    
    ;; Check that allocation is valid
    (asserts! (> allocation-base u0) (err ERR-INVALID-AMOUNT))
    
    ;; Register the user
    (map-set user-rights
      { user: user }
      {
        allocation-base: allocation-base,
        allocation-used: u0,
        last-reset: block-height,
        registered-at: block-height,
        authorized-sources: authorized-sources
      }
    )
    
    (ok true)
  )
)

;; Update a user's water rights
(define-public (update-user-rights (user principal) (new-allocation-base uint) (new-authorized-sources (list 10 uint)))
  (begin
    ;; Check if caller is admin
    (asserts! (is-admin) (err ERR-UNAUTHORIZED))
    
    ;; Check that user exists
    (asserts! (is-some (map-get? user-rights { user: user })) (err ERR-USER-NOT-REGISTERED))
    
    ;; Check that allocation is valid
    (asserts! (> new-allocation-base u0) (err ERR-INVALID-AMOUNT))
    
    (let
      (
        (user-data (unwrap-panic (map-get? user-rights { user: user })))
      )
      ;; Update the user's rights
      (map-set user-rights
        { user: user }
        (merge user-data {
          allocation-base: new-allocation-base,
          authorized-sources: new-authorized-sources
        })
      )
      
      (ok true)
    )
  )
)

;; Claim water allocation (withdraw water)
(define-public (claim-water (source-id uint) (amount uint))
  (begin
    ;; Check that amount is valid
    (asserts! (> amount u0) (err ERR-INVALID-AMOUNT))
    
    ;; Check for drought emergency
    (asserts! (not (var-get drought-emergency)) (err ERR-DROUGHT-EMERGENCY))
    
    ;; Check that source exists
    (asserts! (is-some (map-get? water-sources { source-id: source-id })) (err ERR-SOURCE-NOT-FOUND))
    
    ;; Check that user is registered
    (asserts! (is-some (map-get? user-rights { user: tx-sender })) (err ERR-USER-NOT-REGISTERED))
    
    (let
      (
        (user-data (unwrap-panic (map-get? user-rights { user: tx-sender })))
        (source (unwrap-panic (map-get? water-sources { source-id: source-id })))
        (authorized-sources (get authorized-sources user-data))
      )
      ;; Check that user is authorized to use this source
      (asserts! (is-some (index-of authorized-sources source-id)) (err ERR-UNAUTHORIZED))
      
      ;; Check that source has enough water
      (asserts! (>= (get current-level source) amount) (err ERR-INSUFFICIENT-RIGHTS))
      
      ;; Check that user has sufficient allocation remaining
      (asserts! (has-sufficient-rights tx-sender amount) (err ERR-EXCEEDS-ALLOCATION))
      
      ;; Update the source level
      (asserts! (update-source-level source-id (to-int (* amount u-1))) (err ERR-TRANSFER-FAILED))
      
      ;; Update user's used allocation
      (update-user-allocation tx-sender amount)
      
      ;; Record the transaction
      (record-usage tx-sender source-id amount)
      
      (ok true)
    )
  )
)

;; Transfer water rights from one user to another
(define-public (transfer-water-rights (recipient principal) (amount uint))
  (begin
    ;; Check that amount is valid
    (asserts! (> amount u0) (err ERR-INVALID-AMOUNT))
    
    ;; Check that sender is registered
    (asserts! (is-some (map-get? user-rights { user: tx-sender })) (err ERR-USER-NOT-REGISTERED))
    
    ;; Check that recipient is registered
    (asserts! (is-some (map-get? user-rights { user: recipient })) (err ERR-USER-NOT-REGISTERED))
    
    (let
      (
        (sender-data (unwrap-panic (map-get? user-rights { user: tx-sender })))
        (recipient-data (unwrap-panic (map-get? user-rights { user: recipient })))
        (sender-remaining (- (calculate-allocation (get allocation-base sender-data)) (get allocation-used sender-data)))
      )
      ;; Check that sender has sufficient remaining allocation
      (asserts! (>= sender-remaining amount) (err ERR-INSUFFICIENT-RIGHTS))
      
      ;; Update sender's used allocation
      (map-set user-rights
        { user: tx-sender }
        (merge sender-data {
          allocation-used: (+ (get allocation-used sender-data) amount)
        })
      )
      
      ;; Update recipient's allocation (by effectively reducing their used amount)
      (map-set user-rights
        { user: recipient }
        (merge recipient-data {
          allocation-used: (if (< amount (get allocation-used recipient-data))
                             (- (get allocation-used recipient-data) amount)
                             u0)
        })
      )
      
      (ok true)
    )
  )
)

;; Reset allocation usage (typically done at a regular period)
(define-public (reset-allocation-period)
  (begin
    ;; Check if caller is admin
    (asserts! (is-admin) (err ERR-UNAUTHORIZED))
    
    ;; Function to reset a single user's allocation
    (define-private (reset-user (user principal))
      (let
        (
          (user-data (unwrap! (map-get? user-rights { user: user }) false))
        )
        (map-set user-rights
          { user: user }
          (merge user-data {
            allocation-used: u0,
            last-reset: block-height
          })
        )
        true
      )
    )
    
    ;; Due to Clarity limitations, we can't iterate through all users
    ;; In a real implementation, this would be done by clients calling
    ;; a reset function for each user, or through a batched approach
    
    (ok true)
  )
)

;; Set drought emergency status
(define-public (set-drought-emergency (emergency-active bool))
  (begin
    ;; Check if caller is admin
    (asserts! (is-admin) (err ERR-UNAUTHORIZED))
    
    ;; Check if policy update is allowed
    (asserts! (can-update-policy) (err ERR-POLICY-LOCKED))
    
    ;; Set drought status
    (var-set drought-emergency emergency-active)
    
    ;; Lock policy changes for a period
    (var-set policy-lock-height (+ block-height (var-get policy-lock-duration)))
    
    (ok true)
  )
)

;; Set seasonal adjustment
(define-public (set-seasonal-adjustment (season uint) (multiplier uint))
  (begin
    ;; Check if caller is admin
    (asserts! (is-admin) (err ERR-UNAUTHORIZED))
    
    ;; Check if policy update is allowed
    (asserts! (can-update-policy) (err ERR-POLICY-LOCKED))
    
    ;; Check season is valid (1-4)
    (asserts! (and (>= season u1) (<= season u4)) (err ERR-INVALID-SEASON))
    
    ;; Check multiplier is valid (cannot be zero)
    (asserts! (> multiplier u0) (err ERR-INVALID-AMOUNT))
    
    ;; Set the adjustment
    (map-set seasonal-adjustments
      { season: season }
      { multiplier: multiplier }
    )
    
    ;; Lock policy changes for a period
    (var-set policy-lock-height (+ block-height (var-get policy-lock-duration)))
    
    (ok true)
  )
)

;; Transfer contract ownership
(define-public (transfer-contract-admin (new-admin principal))
  (begin
    ;; Check if caller is the current admin
    (asserts! (is-admin) (err ERR-UNAUTHORIZED))
    
    ;; Transfer admin rights
    (var-set contract-admin new-admin)
    
    (ok true)
  )
)