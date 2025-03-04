{-# OPTIONS --cubical-compatible #-}

postulate
  A : Set
  P : A → Set
  Q : {x : A} → P x → P x → Set

variable
  B    : Set
  @0 q : B

postulate
  F : ∀ p → Q p q → Set

Test : {@0 x : A} ({q} p : P x) (q′ : Q p q) → Set
Test = F
