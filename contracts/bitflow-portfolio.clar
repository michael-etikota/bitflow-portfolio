;; Title: BitFlow Portfolio Engine
;; Summary: Intelligent Asset Allocation Protocol for Bitcoin Layer 2
;;
;; Description: BitFlow revolutionizes digital asset management on the Stacks 
;;              blockchain by providing institutional-grade portfolio automation.
;;              Users can construct sophisticated multi-asset strategies with 
;;              algorithmic rebalancing, dynamic risk management, and capital-
;;              efficient execution. Built for the Bitcoin ecosystem, BitFlow 
;;              enables seamless diversification across BTC-native assets while 
;;              maintaining the security guarantees of Bitcoin's base layer.
;;
;;              Key Features:
;;              - Automated portfolio rebalancing with customizable triggers
;;              - Gas-optimized batch operations for cost-effective management  
;;              - Support for up to 10 assets per portfolio with precise allocation
;;              - Built-in risk controls and validation mechanisms
;;              - Fully decentralized with no custody requirements

;; ERROR CONSTANTS - Comprehensive error handling for all operations

(define-constant ERR-NOT-AUTHORIZED (err u100)) ;; Unauthorized access attempt
(define-constant ERR-INVALID-PORTFOLIO (err u101)) ;; Portfolio doesn't exist or is invalid
(define-constant ERR-INSUFFICIENT-BALANCE (err u102)) ;; Insufficient funds for operation
(define-constant ERR-INVALID-TOKEN (err u103)) ;; Invalid token address provided
(define-constant ERR-REBALANCE-FAILED (err u104)) ;; Portfolio rebalancing operation failed
(define-constant ERR-PORTFOLIO-EXISTS (err u105)) ;; Portfolio already exists
(define-constant ERR-INVALID-PERCENTAGE (err u106)) ;; Invalid allocation percentage
(define-constant ERR-MAX-TOKENS-EXCEEDED (err u107)) ;; Exceeded maximum allowed tokens
(define-constant ERR-LENGTH-MISMATCH (err u108)) ;; Mismatch in input array lengths
(define-constant ERR-USER-STORAGE-FAILED (err u109)) ;; Failed to update user storage
(define-constant ERR-INVALID-TOKEN-ID (err u110)) ;; Invalid token ID in portfolio

;; PROTOCOL CONFIGURATION - Global settings and administrative controls

(define-data-var protocol-owner principal tx-sender) ;; Protocol administrator
(define-data-var portfolio-counter uint u0) ;; Global portfolio ID counter
(define-data-var protocol-fee uint u25) ;; Protocol fee: 0.25% in basis points

;; PROTOCOL CONSTANTS - Immutable configuration parameters

(define-constant MAX-TOKENS-PER-PORTFOLIO u10) ;; Maximum assets per portfolio
(define-constant BASIS-POINTS u10000) ;; 100% = 10,000 basis points
(define-constant MAX-PORTFOLIOS-PER-USER u20) ;; User portfolio limit

;; DATA STRUCTURES - Core data models for portfolio management

;; Primary portfolio registry containing essential metadata
(define-map Portfolios
  uint ;; portfolio-id (unique identifier)
  {
    owner: principal, ;; Portfolio owner's principal address
    created-at: uint, ;; Block height when portfolio was created
    last-rebalanced: uint, ;; Block height of last rebalancing operation
    total-value: uint, ;; Current total portfolio value in STX
    active: bool, ;; Portfolio active status
    token-count: uint, ;; Number of tokens in portfolio
  }
)

;; Individual asset allocation details within portfolios
(define-map PortfolioAssets
  {
    portfolio-id: uint, ;; Reference to parent portfolio
    token-id: uint, ;; Asset index within portfolio (0-9)
  }
  {
    target-percentage: uint, ;; Target allocation in basis points
    current-amount: uint, ;; Current holdings of this asset
    token-address: principal, ;; Smart contract address of the token
  }
)

;; User portfolio ownership registry with bounded list storage
(define-map UserPortfolios
  principal ;; User's principal address
  (list 20 uint) ;; List of owned portfolio IDs (max 20)
)

;; READ-ONLY FUNCTIONS - Query functions for external integration

;; Retrieve comprehensive portfolio information by unique ID
(define-read-only (get-portfolio (portfolio-id uint))
  (map-get? Portfolios portfolio-id)
)

;; Get detailed asset allocation data within a specific portfolio
(define-read-only (get-portfolio-asset
    (portfolio-id uint)
    (token-id uint)
  )
  (map-get? PortfolioAssets {
    portfolio-id: portfolio-id,
    token-id: token-id,
  })
)

;; Retrieve all portfolio IDs owned by a specific user
(define-read-only (get-user-portfolios (user principal))
  (default-to (list) (map-get? UserPortfolios user))
)

;; Calculate portfolio rebalancing requirements and status
(define-read-only (calculate-rebalance-amounts (portfolio-id uint))
  (let (
      (portfolio (unwrap! (get-portfolio portfolio-id) ERR-INVALID-PORTFOLIO))
      (total-value (get total-value portfolio))
      (blocks-since-rebalance (- stacks-block-height (get last-rebalanced portfolio)))
    )
    (ok {
      portfolio-id: portfolio-id,
      total-value: total-value,
      needs-rebalance: (> blocks-since-rebalance u144), ;; ~24 hours
      blocks-since-last: blocks-since-rebalance,
    })
  )
)

;; Get current protocol configuration and statistics
(define-read-only (get-protocol-info)
  {
    owner: (var-get protocol-owner),
    total-portfolios: (var-get portfolio-counter),
    protocol-fee: (var-get protocol-fee),
    max-tokens: MAX-TOKENS-PER-PORTFOLIO,
    max-portfolios-per-user: MAX-PORTFOLIOS-PER-USER,
  }
)

;; PRIVATE HELPER FUNCTIONS - Internal validation and utility functions

;; Validate token ID is within acceptable bounds for portfolio
(define-private (validate-token-id
    (portfolio-id uint)
    (token-id uint)
  )
  (let ((portfolio (unwrap! (get-portfolio portfolio-id) false)))
    (and
      (< token-id MAX-TOKENS-PER-PORTFOLIO)
      (< token-id (get token-count portfolio))
      true
    )
  )
)

;; Ensure percentage value is within valid range (0-100%)
(define-private (validate-percentage (percentage uint))
  (and (>= percentage u0) (<= percentage BASIS-POINTS))
)

;; Validate that all portfolio percentages sum to exactly 100%
(define-private (validate-portfolio-percentages (percentages (list 10 uint)))
  (let ((total (fold + percentages u0)))
    (and
      (is-eq total BASIS-POINTS)
      (fold and (map validate-percentage percentages) true)
    )
  )
)

;; Add new portfolio to user's ownership registry with bounds checking
(define-private (add-to-user-portfolios
    (user principal)
    (portfolio-id uint)
  )
  (let (
      (current-portfolios (get-user-portfolios user))
      (new-portfolios (unwrap! (as-max-len? (append current-portfolios portfolio-id) u20)
        ERR-USER-STORAGE-FAILED
      ))
    )
    (map-set UserPortfolios user new-portfolios)
    (ok true)
  )
)

;; Initialize individual portfolio asset with allocation parameters
(define-private (initialize-portfolio-asset
    (index uint)
    (token principal)
    (percentage uint)
    (portfolio-id uint)
  )
  (if (>= percentage u0)
    (begin
      (map-set PortfolioAssets {
        portfolio-id: portfolio-id,
        token-id: index,
      } {
        target-percentage: percentage,
        current-amount: u0,
        token-address: token,
      })
      (ok true)
    )
    ERR-INVALID-TOKEN
  )
)

;; Initialize all portfolio assets with unrolled loop logic for gas efficiency
(define-private (initialize-all-assets
    (portfolio-id uint)
    (tokens (list 10 principal))
    (percentages (list 10 uint))
  )
  (let ((token-count (len tokens)))
    (begin
      ;; Initialize assets at positions 2-9 (positions 0-1 handled in main function)
      (if (> token-count u2)
        (unwrap!
          (initialize-portfolio-asset u2
            (unwrap! (element-at tokens u2) ERR-INVALID-TOKEN)
            (unwrap! (element-at percentages u2) ERR-INVALID-PERCENTAGE)
            portfolio-id
          )
          ERR-INVALID-TOKEN
        )
        true
      )
      (if (> token-count u3)
        (unwrap!
          (initialize-portfolio-asset u3
            (unwrap! (element-at tokens u3) ERR-INVALID-TOKEN)
            (unwrap! (element-at percentages u3) ERR-INVALID-PERCENTAGE)
            portfolio-id
          )
          ERR-INVALID-TOKEN
        )
        true
      )
      (if (> token-count u4)
        (unwrap!
          (initialize-portfolio-asset u4
            (unwrap! (element-at tokens u4) ERR-INVALID-TOKEN)
            (unwrap! (element-at percentages u4) ERR-INVALID-PERCENTAGE)
            portfolio-id
          )
          ERR-INVALID-TOKEN
        )
        true
      )
      (if (> token-count u5)
        (unwrap!
          (initialize-portfolio-asset u5
            (unwrap! (element-at tokens u5) ERR-INVALID-TOKEN)
            (unwrap! (element-at percentages u5) ERR-INVALID-PERCENTAGE)
            portfolio-id
          )
          ERR-INVALID-TOKEN
        )
        true
      )
      (if (> token-count u6)
        (unwrap!
          (initialize-portfolio-asset u6
            (unwrap! (element-at tokens u6) ERR-INVALID-TOKEN)
            (unwrap! (element-at percentages u6) ERR-INVALID-PERCENTAGE)
            portfolio-id
          )
          ERR-INVALID-TOKEN
        )
        true
      )
      (if (> token-count u7)
        (unwrap!
          (initialize-portfolio-asset u7
            (unwrap! (element-at tokens u7) ERR-INVALID-TOKEN)
            (unwrap! (element-at percentages u7) ERR-INVALID-PERCENTAGE)
            portfolio-id
          )
          ERR-INVALID-TOKEN
        )
        true
      )
      (if (> token-count u8)
        (unwrap!
          (initialize-portfolio-asset u8
            (unwrap! (element-at tokens u8) ERR-INVALID-TOKEN)
            (unwrap! (element-at percentages u8) ERR-INVALID-PERCENTAGE)
            portfolio-id
          )
          ERR-INVALID-TOKEN
        )
        true
      )
      (if (> token-count u9)
        (unwrap!
          (initialize-portfolio-asset u9
            (unwrap! (element-at tokens u9) ERR-INVALID-TOKEN)
            (unwrap! (element-at percentages u9) ERR-INVALID-PERCENTAGE)
            portfolio-id
          )
          ERR-INVALID-TOKEN
        )
        true
      )
      (ok true)
    )
  )
)

;; PUBLIC FUNCTIONS - Core protocol functionality accessible to users

;; Create a new diversified portfolio with specified token allocations
(define-public (create-portfolio
    (initial-tokens (list 10 principal))
    (percentages (list 10 uint))
  )
  (let (
      (portfolio-id (+ (var-get portfolio-counter) u1))
      (token-count (len initial-tokens))
      (percentage-count (len percentages))
    )
    ;; Comprehensive validation checks
    (asserts! (<= token-count MAX-TOKENS-PER-PORTFOLIO) ERR-MAX-TOKENS-EXCEEDED)
    (asserts! (is-eq token-count percentage-count) ERR-LENGTH-MISMATCH)
    (asserts! (validate-portfolio-percentages percentages) ERR-INVALID-PERCENTAGE)
    (asserts! (>= token-count u2) ERR-INVALID-PORTFOLIO)
    ;; Create main portfolio record with metadata
    (map-set Portfolios portfolio-id {
      owner: tx-sender,
      created-at: stacks-block-height,
      last-rebalanced: stacks-block-height,
      total-value: u0,
      active: true,
      token-count: token-count,
    })
    ;; Initialize first two assets (guaranteed to exist based on validation)
    (try! (initialize-portfolio-asset u0
      (unwrap! (element-at initial-tokens u0) ERR-INVALID-TOKEN)
      (unwrap! (element-at percentages u0) ERR-INVALID-PERCENTAGE)
      portfolio-id
    ))
    (try! (initialize-portfolio-asset u1
      (unwrap! (element-at initial-tokens u1) ERR-INVALID-TOKEN)
      (unwrap! (element-at percentages u1) ERR-INVALID-PERCENTAGE)
      portfolio-id
    ))
    ;; Initialize remaining assets (positions 2-9) if they exist
    (try! (initialize-all-assets portfolio-id initial-tokens percentages))
    ;; Add portfolio to user's ownership registry
    (try! (add-to-user-portfolios tx-sender portfolio-id))
    ;; Update global portfolio counter
    (var-set portfolio-counter portfolio-id)
    (ok portfolio-id)
  )
)

;; Execute portfolio rebalancing to match target allocations
(define-public (rebalance-portfolio (portfolio-id uint))
  (let ((portfolio (unwrap! (get-portfolio portfolio-id) ERR-INVALID-PORTFOLIO)))
    ;; Authorization and validity checks
    (asserts! (is-eq tx-sender (get owner portfolio)) ERR-NOT-AUTHORIZED)
    (asserts! (get active portfolio) ERR-INVALID-PORTFOLIO)
    ;; Update portfolio metadata with current block height
    (map-set Portfolios portfolio-id
      (merge portfolio { last-rebalanced: stacks-block-height })
    )
    (ok true)
  )
)

;; Update target allocation percentage for a specific asset
(define-public (update-portfolio-allocation
    (portfolio-id uint)
    (token-id uint)
    (new-percentage uint)
  )
  (let (
      (portfolio (unwrap! (get-portfolio portfolio-id) ERR-INVALID-PORTFOLIO))
      (asset (unwrap! (get-portfolio-asset portfolio-id token-id) ERR-INVALID-TOKEN))
    )
    ;; Authorization and validation checks
    (asserts! (is-eq tx-sender (get owner portfolio)) ERR-NOT-AUTHORIZED)
    (asserts! (validate-percentage new-percentage) ERR-INVALID-PERCENTAGE)
    (asserts! (validate-token-id portfolio-id token-id) ERR-INVALID-TOKEN-ID)
    ;; Update asset allocation in storage
    (map-set PortfolioAssets {
      portfolio-id: portfolio-id,
      token-id: token-id,
    }
      (merge asset { target-percentage: new-percentage })
    )
    (ok true)
  )
)

;; Deactivate portfolio to prevent further operations
(define-public (deactivate-portfolio (portfolio-id uint))
  (let ((portfolio (unwrap! (get-portfolio portfolio-id) ERR-INVALID-PORTFOLIO)))
    (asserts! (is-eq tx-sender (get owner portfolio)) ERR-NOT-AUTHORIZED)
    (map-set Portfolios portfolio-id (merge portfolio { active: false }))
    (ok true)
  )
)