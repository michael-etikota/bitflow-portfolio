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