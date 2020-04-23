{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_HADDOCK prune #-}

-- |
-- Copyright: © 2018-2020 IOHK
-- License: Apache-2.0
--
-- Provides functionality for __adjusting__ coin selections in order to pay for
-- transaction __fees__.
--
module Cardano.Fee
    (
      -- * Fundamental Types
      Fee (..)
    , FeeEstimator (..)

      -- * Fee Adjustment
    , adjustForFee
    , FeeOptions (..)
    , FeeAdjustmentError (..)

      -- * Dust Processing
    , DustThreshold (..)
    , coalesceDust

      -- # Internal Functions
    , calculateFee
    , distributeFee
    , reduceChangeOutputs
    , splitCoin

    ) where

import Prelude hiding
    ( round )

import Cardano.CoinSelection
    ( CoinMap (..)
    , CoinMapEntry (..)
    , CoinSelection (..)
    , coinMapFromList
    , coinMapRandomEntry
    , sumChange
    , sumInputs
    , sumOutputs
    )
import Control.Monad.Trans.Class
    ( lift )
import Control.Monad.Trans.Except
    ( ExceptT (..), throwE )
import Control.Monad.Trans.State
    ( StateT (..), evalStateT )
import Crypto.Random.Types
    ( MonadRandom )
import Data.Function
    ( (&) )
import Data.List.NonEmpty
    ( NonEmpty ((:|)) )
import Data.Maybe
    ( fromMaybe )
import Data.Ord
    ( Down (..), comparing )
import Data.Ratio
    ( (%) )
import GHC.Generics
    ( Generic )
import GHC.Stack
    ( HasCallStack )
import Internal.Coin
    ( Coin )
import Internal.Invariant
    ( invariant )
import Internal.Rounding
    ( RoundingDirection (..), round )
import Quiet
    ( Quiet (Quiet) )

import qualified Data.Foldable as F
import qualified Data.List.NonEmpty as NE
import qualified Internal.Coin as C

--------------------------------------------------------------------------------
-- Fundamental Types
--------------------------------------------------------------------------------

-- | Represents a non-negative fee to be paid on a transaction.
--
newtype Fee = Fee { unFee :: Coin }
    deriving newtype (Monoid, Semigroup)
    deriving stock (Eq, Generic, Ord)
    deriving Show via (Quiet Fee)

-- | Defines the maximum size of a dust coin.
--
-- Change values that are less than or equal to this threshold will not be
-- included in coin selections produced by the 'adjustForFee' function.
--
newtype DustThreshold = DustThreshold { unDustThreshold :: Coin }
    deriving stock (Eq, Generic, Ord)
    deriving Show via (Quiet DustThreshold)

-- | Provides a function capable of estimating the fee for a given coin
--   selection.
--
-- The fee estimate can depend on the numbers of inputs, outputs, and change
-- outputs within the coin selection, as well as their magnitudes.
--
newtype FeeEstimator i o = FeeEstimator
    { estimateFee :: CoinSelection i o -> Fee
    } deriving Generic

--------------------------------------------------------------------------------
-- Fee Adjustment
--------------------------------------------------------------------------------

-- | Provides options for fee adjustment.
--
data FeeOptions i o = FeeOptions
    { feeEstimator
        :: FeeEstimator i o
    , dustThreshold
        :: DustThreshold
    } deriving Generic

-- | Represents the set of possible failures that can occur when adjusting a
--   'CoinSelection' with the 'adjustForFee' function.
--
newtype FeeAdjustmentError
    = CannotCoverFee Fee
    -- ^ Indicates that the given map of additional inputs was exhausted while
    --   attempting to select extra inputs to cover the required fee.
    --
    -- Records the shortfall (__/f/__ − __/s/__) between the required fee
    -- __/f/__ and the total value __/s/__ of currently-selected inputs.
    --
    deriving (Show, Eq)

-- | Adjusts the given 'CoinSelection' in order to pay for a __transaction__
--   __fee__, required in order to publish the selection as a transaction on
--   a blockchain.
--
-- == Background
--
-- Implementations of 'Cardano.CoinSelection.CoinSelectionAlgorithm' generally
-- produce coin selections that are /exactly balanced/, satisfying the
-- following equality:
--
-- >>> sumInputs c = sumOutputs c + sumChange c
--
-- In order to pay for a transaction fee, the above equality must be
-- transformed into an /inequality/:
--
-- >>> sumInputs c > sumOutputs c + sumChange c
--
-- The difference between these two sides represents value to be paid /by the/
-- /originator/ of the transaction, in the form of a fee:
--
-- >>> sumInputs c = sumOutputs c + sumChange c + fee
--
-- == The Adjustment Process
--
-- In order to generate a fee that is acceptable to the network, this function
-- adjusts the 'change' and 'inputs' of the given 'CoinSelection', consulting
-- the 'FeeEstimator' as a guide for how much the current selection would cost
-- to publish as a transaction on the network.
--
-- == Methods of Adjustment
--
-- There are two methods of adjustment possible:
--
--  1. The __'change'__ set can be /reduced/, either by:
--
--      a. completely removing a change value from the set; or by
--
--      b. reducing a change value to a lower value.
--
--  2. The __'inputs'__ set can be /augmented/, by selecting additional inputs
--     from the specified 'CoinMap' argument.
--
-- == Dealing with Dust Values
--
-- If, at any point, a change value is generated that is less than or equal
-- to the 'DustThreshold', this function will eliminate that change value
-- from the 'change' set, redistributing the eliminated value over the remaining
-- change values, ensuring that the total value of all 'change' is preserved.
--
-- See 'coalesceDust' for more details.
--
-- == Termination
--
-- Since adjusting a selection can affect the fee estimate produced by
-- 'estimateFee', the process of adjustment is an /iterative/ process.
--
-- This function terminates when it has generated a 'CoinSelection' that
-- satisfies the following property:
--
-- >>> sumInputs c ≈ sumOutputs c + sumChange c + estimateFee c
--
adjustForFee
    :: (Ord i, Show i, Show o, MonadRandom m)
    => FeeOptions i o
    -> CoinMap i
    -> CoinSelection i o
    -> ExceptT FeeAdjustmentError m (CoinSelection i o)
adjustForFee unsafeOpt utxo coinSel = do
    let opt = invariant
            "adjustForFee: fee must be non-null" unsafeOpt (not . nullFee)
    senderPaysFee opt utxo coinSel
  where
    nullFee opt = estimateFee (feeEstimator opt) coinSel == Fee C.zero

--------------------------------------------------------------------------------
-- Internal Functions
--------------------------------------------------------------------------------

-- Calculates the current fee associated with a given 'CoinSelection'.
--
-- If the result is less than zero, returns 'Nothing'.
--
calculateFee :: CoinSelection i o -> Maybe Fee
calculateFee s = Fee <$> sumInputs s `C.sub` (sumOutputs s `C.add` sumChange s)

-- The sender pays fee in this scenario, so fees are removed from the change
-- outputs, and new inputs are selected if necessary.
--
senderPaysFee
    :: forall i o m . (Ord i, Show i, Show o, MonadRandom m)
    => FeeOptions i o
    -> CoinMap i
    -> CoinSelection i o
    -> ExceptT FeeAdjustmentError m (CoinSelection i o)
senderPaysFee FeeOptions {feeEstimator, dustThreshold} utxo sel =
    evalStateT (go sel) utxo
  where
    go
        :: CoinSelection i o
        -> StateT (CoinMap i) (ExceptT FeeAdjustmentError m) (CoinSelection i o)
    go coinSel@(CoinSelection inps outs chgs) = do
        -- 1/
        -- We compute fees using all inputs, outputs and changes since all of
        -- them have an influence on the fee calculation.
        let feeUpperBound = estimateFee feeEstimator coinSel
        -- 2/
        -- Substract fee from change outputs, proportionally to their value.
        let chgs' = reduceChangeOutputs dustThreshold feeUpperBound chgs
        let coinSel' = coinSel { change = chgs' }
        let remFee = remainingFee feeEstimator coinSel'
        -- 3.1/
        -- Should the change cover the fee, we're (almost) good. By removing
        -- change outputs, we make them smaller and may reduce the size of the
        -- transaction, and the fee. Thus, we end up paying slightly more than
        -- the upper bound. We could do some binary search and try to
        -- re-distribute excess across changes until fee becomes bigger.
        if remFee == Fee C.zero
        then pure coinSel'
        else do
            -- 3.2/
            -- Otherwise, we need an extra entries from the available utxo to
            -- cover what's left. Note that this entry may increase our change
            -- because we may not consume it entirely. So we will just split
            -- the extra change across all changes possibly increasing the
            -- number of change outputs (if there was none, or if increasing a
            -- change value causes an overflow).
            --
            -- Because selecting a new input increases the fee, we need to
            -- re-run the algorithm with this new elements and using the initial
            -- change plus the extra change brought up by this entry and see if
            -- we can now correctly cover fee.
            inps' <- coverRemainingFee remFee
            let extraChange = splitCoin (sumEntries inps') chgs
            go $ CoinSelection (inps <> coinMapFromList inps') outs extraChange

-- A short and simple version of the 'random' fee policy to cover for the fee
-- in the case where existing set of change is not enough.
--
coverRemainingFee
    :: MonadRandom m
    => Fee
    -> StateT (CoinMap i) (ExceptT FeeAdjustmentError m) [CoinMapEntry i]
coverRemainingFee (Fee fee) = go [] where
    go acc
        | sumEntries acc >= fee =
            return acc
        | otherwise = do
            -- We ignore the size of the fee, and just pick randomly
            StateT (lift . coinMapRandomEntry) >>= \case
                Just entry ->
                    go (entry : acc)
                Nothing ->
                    lift $ throwE $ CannotCoverFee $ Fee $
                        fee `C.distance` (sumEntries acc)

-- Pays for the given fee by subtracting it from the given list of change
-- outputs, so that each change output is reduced by a portion of the fee
-- that's in proportion to its relative size.
--
-- == Basic Examples
--
-- >>> reduceChangeOutputs (DustThreshold 0) (Fee 4) (Coin <$> [2, 2, 2, 2])
-- [Coin 1, Coin 1, Coin 1, Coin 1]
--
-- >>> reduceChangeOutputs (DustThreshold 0) (Fee 15) (Coin <$> [2, 4, 8, 16])
-- [Coin 1, Coin 2, Coin 4, Coin 8]
--
-- == Handling Dust
--
-- Any dust outputs in the resulting list are coalesced according to the given
-- dust threshold: (See 'coalesceDust'.)
--
-- >>> reduceChangeOutputs (DustThreshold 1) (Fee 4) (Coin <$> [2, 2, 2, 2])
-- [Coin 4]
--
-- == Handling Insufficient Change
--
-- If there's not enough change to pay for the fee, or if there's only just
-- enough to pay for it exactly, this function returns the /empty list/:
--
-- >>> reduceChangeOutputs (DustThreshold 0) (Fee 15) (Coin <$> [10])
-- []
--
-- >>> reduceChangeOutputs (DustThreshold 0) (Fee 15) (Coin <$> [1, 2, 4, 8])
-- []
--
reduceChangeOutputs :: DustThreshold -> Fee -> [Coin] -> [Coin]
reduceChangeOutputs threshold (Fee totalFee) changeOutputs
    | totalFee >= totalChange =
        []
    | otherwise =
        case positiveChangeOutputs of
            x : xs -> x :| xs
                & distributeFee (Fee totalFee)
                & fmap payFee
                & coalesceDust threshold
            [] -> []
  where
    payFee :: (Fee, Coin) -> Coin
    payFee (Fee f, c) =
        fromMaybe C.zero (c `C.sub` f)

    positiveChangeOutputs :: [Coin]
    positiveChangeOutputs = filter (> C.zero) changeOutputs

    totalChange = F.fold changeOutputs

-- Distribute the given fee over the given list of coins, so that each coin
-- is allocated a __fraction__ of the fee in proportion to its relative size.
--
-- == Pre-condition
--
-- Every coin in the given list must be __non-zero__ in value.
--
-- == Examples
--
-- >>> distributeFee (Fee 2) [(Coin 1), (Coin 1)]
-- [(Fee 1, Coin 1), (Fee 1, Coin 1)]
--
-- >>> distributeFee (Fee 4) [(Coin 1), (Coin 1)]
-- [(Fee 2, Coin 1), (Fee 2, Coin 1)]
--
-- >>> distributeFee (Fee 7) [(Coin 1), (Coin 2), (Coin 4)]
-- [(Fee 1, Coin 1), (Fee 2, Coin 2), (Fee 4, Coin 4)]
--
-- >>> distributeFee (Fee 14) [(Coin 1), (Coin 2), (Coin 4)]
-- [(Fee 2, Coin 1), (Fee 4, Coin 2), (Fee 8, Coin 4)]
--
distributeFee :: Fee -> NonEmpty Coin -> NonEmpty (Fee, Coin)
distributeFee (Fee feeTotal) coinsUnsafe =
    NE.zip feesRounded coins
  where
    -- A list of coins that are non-zero in value.
    coins :: NonEmpty Coin
    coins =
        invariant "distributeFee: all coins must be non-zero in value."
        coinsUnsafe (C.zero `F.notElem`)

    -- A list of rounded fee portions, where each fee portion deviates from the
    -- ideal unrounded portion by as small an amount as possible.
    feesRounded :: NonEmpty Fee
    feesRounded
        -- 1. Start with the list of ideal unrounded fee portions for each coin:
        = feesUnrounded
        -- 2. Attach an index to each fee portion, so that we can remember the
        --    original order:
        & NE.zip indices
        -- 3. Sort the fees into descending order of their fractional parts:
        & NE.sortBy (comparing (Down . fractionalPart . snd))
        -- 4. Apply pre-computed roundings to each fee portion:
        --    * portions with the greatest fractional parts are rounded up;
        --    * portions with the smallest fractional parts are rounded down.
        & NE.zipWith (\roundDir (i, f) -> (i, round roundDir f)) feeRoundings
        -- 5. Restore the original order:
        & NE.sortBy (comparing fst)
        -- 6. Strip away the indices:
        & fmap snd
        -- 7. Transform results into fees:
        & fmap (Fee . fromMaybe C.zero . C.coinFromIntegral @Integer)
      where
        indices :: NonEmpty Int
        indices = 0 :| [1 ..]

    -- A list of rounding directions, one per fee portion.
    --
    -- Since the ideal fee portion for each coin is a rational value, we must
    -- therefore round each rational value either /up/ or /down/ to produce a
    -- final integer result.
    --
    -- However, we can't take the simple approach of either rounding /all/ fee
    -- portions down or rounding /all/ fee portions up, as this could cause the
    -- sum of fee portions to either undershoot or overshoot the original fee.
    --
    -- So in order to hit the fee exactly, we must round /some/ of the portions
    -- up, and /some/ of the portions down.
    --
    -- Fortunately, we can calculate exactly how many fee portions must be
    -- rounded up, by first rounding /all/ portions down, and then computing
    -- the /shortfall/ between the sum of the rounded-down portions and the
    -- original fee.
    --
    -- We return a list where all values of 'RoundUp' occur in a contiguous
    -- section at the start of the list, of the following form:
    --
    --     [RoundUp, RoundUp, ..., RoundDown, RoundDown, ...]
    --
    feeRoundings :: NonEmpty RoundingDirection
    feeRoundings =
        applyN feeShortfall (NE.cons RoundUp) (NE.repeat RoundDown)
      where
         -- The part of the total fee that we'd lose if we were to take the
         -- simple approach of rounding all ideal fee portions /down/.
        feeShortfall
            = C.coinToIntegral feeTotal
            - fromIntegral @Integer (F.sum $ round RoundDown <$> feesUnrounded)

    -- A list of ideal unrounded fee portions, with one fee portion per coin.
    --
    -- A coin's ideal fee portion is the rational portion of the total fee that
    -- corresponds to that coin's relative size when compared to other coins.
    feesUnrounded :: NonEmpty Rational
    feesUnrounded = calculateIdealFee <$> coins
      where
        calculateIdealFee c
            = C.coinToIntegral c
            * C.coinToIntegral feeTotal
            % C.coinToIntegral totalCoinValue

    -- The total value of all coins.
    totalCoinValue :: Coin
    totalCoinValue = F.fold coins

-- | From the given list of coins, remove dust coins with a value less than or
--   equal to the given threshold value, redistributing their total value over
--   the coins that remain.
--
-- This function satisfies the following properties:
--
-- >>> sum coins = sum (coalesceDust threshold coins)
-- >>> all (/= Coin 0) (coalesceDust threshold coins)
--
coalesceDust :: DustThreshold -> NonEmpty Coin -> [Coin]
coalesceDust (DustThreshold threshold) coins =
    splitCoin valueToDistribute coinsToKeep
  where
    (coinsToKeep, coinsToRemove) = NE.partition (> threshold) coins
    valueToDistribute = F.fold coinsToRemove

-- Computes how much is left to pay given a particular selection.
--
remainingFee
    :: (HasCallStack, Show i, Show o)
    => FeeEstimator i o
    -> CoinSelection i o
    -> Fee
remainingFee FeeEstimator {estimateFee} s
    | fee >= diff =
        Fee (fee `C.distance` diff)
    | feeDangling >= diff =
        Fee (feeDangling `C.distance` fee)
    | otherwise =
        -- NOTE
        -- The only case where we may end up with an unbalanced transaction is
        -- when we have a dangling change output (i.e. adding it costs too much
        -- and we can't afford it, but not having it result in too many coins
        -- left for fees).
        error $ unwords
            [ "Generated an unbalanced tx! Too much left for fees"
            , ": fee (raw) =", show fee
            , ": fee (dangling) =", show feeDangling
            , ", diff =", show diff
            , "\nselection =", show s
            ]
  where
    Fee fee = estimateFee s
    Fee diff = fromMaybe errorUnderfundedSelection (calculateFee s)
    Fee feeDangling = estimateFee s { change = [diff `C.distance` fee] }
    errorUnderfundedSelection = error
        "Cannot calculate remaining fee for an underfunded selection."

-- Splits up the given coin of value __@v@__, distributing its value over the
-- given coin list of length __@n@__, so that each coin value is increased by
-- an integral amount within unity of __@v/n@__, producing a new list of coin
-- values where the overall total is preserved.
--
-- == Basic Examples
--
-- When it's possible to divide a coin evenly, each coin value is increased by
-- the same integer amount:
--
-- >>> splitCoin (Coin 40) (Coin <$> [1, 1, 1, 1])
-- [Coin 11, Coin 11, Coin 11, Coin 11]
--
-- >>> splitCoin (Coin 40) (Coin <$> [1, 2, 3, 4])
-- [Coin 11, Coin 12, Coin 13, Coin 14]
--
-- == Handling Non-Uniform Increases
--
-- When it's not possible to divide a coin evenly, each integral coin value in
-- the resulting list is always within unity of the ideal unrounded result:
--
-- >>> splitCoin (Coin 2) (Coin <$> [1, 1, 1, 1])
-- [Coin 1, Coin 1, Coin 2, Coin 2]
--
-- >>> splitCoin (Coin 10) (Coin <$> [1, 1, 1, 1])
-- [Coin 3, Coin 3, Coin 4, Coin 4]
--
-- == Handling Empty Lists
--
-- If the given list is empty, this function returns a list with the original
-- given coin as its sole element:
--
-- >>> splitCoin (Coin 10) []
-- [Coin 10]
--
-- == Properties
--
-- The total value is always preserved:
--
-- >>> sum (splitCoin x ys) == x + sum ys
--
splitCoin :: Coin -> [Coin] -> [Coin]
splitCoin coinToSplit coinsToIncrease =
    case (mIncrement, mShortfall) of
        (Just increment, Just shortfall) ->
            zipWith C.add coinsToIncrease increments
          where
            increments = zipWith C.add majorIncrements minorIncrements
            majorIncrements = repeat increment
            minorIncrements = replicate (C.coinToIntegral shortfall) C.one
                <> repeat C.zero
        _ | coinToSplit > C.zero ->
            [coinToSplit]
        _ ->
            []
  where
    mCoinCount = length coinsToIncrease
    mIncrement = coinToSplit `C.div` mCoinCount
    mShortfall = coinToSplit `C.mod` mCoinCount

-- Extract the fractional part of a rational number.
--
-- Examples:
--
-- >>> fractionalPart (3 % 2)
-- 1 % 2
--
-- >>> fractionalPart (11 % 10)
-- 1 % 10
--
fractionalPart :: Rational -> Rational
fractionalPart = snd . properFraction @_ @Integer

-- Apply the same function multiple times to a value.
--
applyN :: Int -> (a -> a) -> a -> a
applyN n f = F.foldr (.) id (replicate n f)

-- Find the sum of a list of entries.
--
sumEntries :: [CoinMapEntry i] -> Coin
sumEntries = F.fold . fmap entryValue