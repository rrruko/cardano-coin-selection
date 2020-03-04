{-# LANGUAGE RankNTypes #-}

-- |
-- Copyright: © 2018-2020 IOHK
-- License: Apache-2.0
--
-- This module contains an implementation of the __Largest-First__ coin
-- selection algorithm.
--
module Cardano.CoinSelection.LargestFirst (
    largestFirst
  ) where

import Prelude

import Cardano.CoinSelection
    ( CoinSelection (..), CoinSelectionOptions (..), ErrCoinSelection (..) )
import Cardano.Types
    ( Coin (..), TxIn, TxOut (..), UTxO (..), balance )
import Control.Arrow
    ( left )
import Control.Monad
    ( foldM )
import Control.Monad.Trans.Except
    ( ExceptT (..), except, throwE )
import Data.Functor
    ( ($>) )
import Data.List.NonEmpty
    ( NonEmpty (..) )
import Data.Ord
    ( Down (..) )

import qualified Data.List as L
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map

-- | Implements the __Largest-First__ coin selection algorithm.
largestFirst
    :: forall m e. Monad m
    => CoinSelectionOptions e
    -> NonEmpty TxOut
    -> UTxO
    -> ExceptT (ErrCoinSelection e) m (CoinSelection, UTxO)
largestFirst options outputsRequested utxo =
    case foldM atLeast (utxoDescending, mempty) outputsDescending of
        Just (utxoRemaining, selection) ->
            validateSelection selection $>
                (selection, UTxO $ Map.fromList utxoRemaining)
        Nothing ->
            throwE errorCondition
  where
    errorCondition
      | amountAvailable < amountRequested =
          ErrNotEnoughMoney amountAvailable amountRequested
      | utxoCount < outputCount =
          ErrUtxoNotFragmentedEnough utxoCount outputCount
      | utxoCount <= inputCountMax =
          ErrInputsDepleted
      | otherwise =
          ErrMaximumInputsReached inputCountMax
    amountAvailable =
        fromIntegral $ balance utxo
    amountRequested =
        sum $ (getCoin . coin) <$> outputsRequested
    inputCountMax =
        fromIntegral $ maximumNumberOfInputs options $ fromIntegral outputCount
    outputCount =
        fromIntegral $ NE.length outputsRequested
    outputsDescending =
        L.sortOn (Down . coin) $ NE.toList outputsRequested
    utxoCount =
        fromIntegral $ L.length $ (Map.toList . getUTxO) utxo
    utxoDescending =
        take (fromIntegral inputCountMax)
            $ L.sortOn (Down . coin . snd)
            $ Map.toList
            $ getUTxO utxo
    validateSelection =
        except . left ErrInvalidSelection . validate options

-- Selects coins to cover at least the specified value.
--
-- The details of the algorithm are as follows:
--
-- (a) transaction outputs are processed starting from the largest first.
--
-- (b) `maximumNumberOfInputs` biggest available UTxO inputs are taken into
--     consideration. They constitute a candidate UTxO inputs from which coin
--     selection will be tried. Each output is treated independently with the
--     heuristic described in (c).
--
-- (c) the biggest candidate UTxO input is tried first to cover the transaction
--     output. If the input is not enough, then the next biggest one is added
--     to check if they can cover the transaction output. This process is
--     continued until the output is covered or the candidates UTxO inputs are
--     depleted.  In the latter case `MaximumInputsReached` error is triggered.
--     If the transaction output is covered the next biggest one is processed.
--     Here, the biggest UTxO input, not participating in the coverage, is
--     taken. We are back at (b) step as a result
--
-- The steps are continued until all transaction are covered.
atLeast
    :: ([(TxIn, TxOut)], CoinSelection)
    -> TxOut
    -> Maybe ([(TxIn, TxOut)], CoinSelection)
atLeast (utxoAvailable, currentSelection) txout =
    let target = fromIntegral $ getCoin $ coin txout in
    coverTarget target utxoAvailable mempty
  where
    coverTarget
        :: Integer
        -> [(TxIn, TxOut)]
        -> [(TxIn, TxOut)]
        -> Maybe ([(TxIn, TxOut)], CoinSelection)
    coverTarget target utxoRemaining utxoSelected
        | target <= 0 = Just
            -- We've selected enough to cover the target, so stop here.
            ( utxoRemaining
            , currentSelection <> CoinSelection
                { inputs  = utxoSelected
                , outputs = [txout]
                , change  = [Coin $ fromIntegral $ abs target | target < 0]
                }
            )
        | otherwise =
            -- We haven't yet selected enough to cover the target, so attempt
            -- to select a little more and then continue.
            case utxoRemaining of
                (i, o):utxoRemaining' ->
                    let utxoSelected' = (i, o):utxoSelected
                        target' = target - fromIntegral (getCoin (coin o))
                    in
                    coverTarget target' utxoRemaining' utxoSelected'
                [] ->
                    -- The UTxO has been exhausted, so stop here.
                    Nothing
