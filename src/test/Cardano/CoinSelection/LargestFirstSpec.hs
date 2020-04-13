{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.CoinSelection.LargestFirstSpec
    ( spec
    ) where

import Prelude

import Cardano.CoinSelection
    ( Coin (..)
    , CoinMap (..)
    , CoinMapEntry (..)
    , CoinSelection (..)
    , CoinSelectionAlgorithm (..)
    , CoinSelectionError (..)
    , CoinSelectionOptions (..)
    , coinMapToList
    )
import Cardano.CoinSelection.LargestFirst
    ( largestFirst )
import Cardano.CoinSelectionSpec
    ( CoinSelProp (..)
    , CoinSelectionFixture (..)
    , CoinSelectionResult (..)
    , ErrValidation (..)
    , alwaysFail
    , coinSelectionUnitTest
    , noValidation
    )
import Cardano.Test.Utilities
    ( Address, TxIn, excluding )
import Control.Monad
    ( unless )
import Control.Monad.Trans.Except
    ( runExceptT )
import Data.Either
    ( isRight )
import Data.Functor.Identity
    ( Identity (runIdentity) )
import Test.Hspec
    ( Spec, describe, it, shouldSatisfy )
import Test.QuickCheck
    ( Property, property, (==>) )

import qualified Data.List as L
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

spec :: Spec
spec = do
    describe "Coin selection: largest-first algorithm: unit tests" $ do

        coinSelectionUnitTest largestFirst ""
            (Right $ CoinSelectionResult
                { rsInputs = [17]
                , rsChange = []
                , rsOutputs = [17]
                })
            (CoinSelectionFixture
                { maxNumOfInputs = 100
                , validateSelection = noValidation
                , utxoInputs = [10,10,17]
                , txOutputs = [17]
                })

        coinSelectionUnitTest largestFirst ""
            (Right $ CoinSelectionResult
                { rsInputs = [17]
                , rsChange = [16]
                , rsOutputs = [1]
                })
            (CoinSelectionFixture
                { maxNumOfInputs = 100
                , validateSelection = noValidation
                , utxoInputs = [12,10,17]
                , txOutputs = [1]
                })

        coinSelectionUnitTest largestFirst ""
            (Right $ CoinSelectionResult
                { rsInputs = [12, 17]
                , rsChange = [11]
                , rsOutputs = [18]
                })
            (CoinSelectionFixture
                { maxNumOfInputs = 100
                , validateSelection = noValidation
                , utxoInputs = [12,10,17]
                , txOutputs = [18]
                })

        coinSelectionUnitTest largestFirst ""
            (Right $ CoinSelectionResult
                { rsInputs = [10, 12, 17]
                , rsChange = [9]
                , rsOutputs = [30]
                })
            (CoinSelectionFixture
                { maxNumOfInputs = 100
                , validateSelection = noValidation
                , utxoInputs = [12,10,17]
                , txOutputs = [30]
                })

        coinSelectionUnitTest largestFirst ""
            (Right $ CoinSelectionResult
                { rsInputs = [6,10,5]
                , rsChange = [5,4]
                , rsOutputs = [11,1]
                })
            (CoinSelectionFixture
                { maxNumOfInputs = 3
                , validateSelection = noValidation
                , utxoInputs = [1,2,10,6,5]
                , txOutputs = [11, 1]
                })

        coinSelectionUnitTest largestFirst
            "UTxO balance not sufficient"
            (Left $ ErrUtxoBalanceInsufficient 39 40)
            (CoinSelectionFixture
                { maxNumOfInputs = 100
                , validateSelection = noValidation
                , utxoInputs = [12,10,17]
                , txOutputs = [40]
                })

        coinSelectionUnitTest largestFirst
            "UTxO balance not sufficient, and not fragmented enough"
            (Left $ ErrUtxoBalanceInsufficient 39 43)
            (CoinSelectionFixture
                { maxNumOfInputs = 100
                , validateSelection = noValidation
                , utxoInputs = [12,10,17]
                , txOutputs = [40,1,1,1]
                })

        coinSelectionUnitTest largestFirst
            "UTxO balance sufficient, but not fragmented enough"
            (Left $ ErrUtxoNotFragmentedEnough 3 4)
            (CoinSelectionFixture
                { maxNumOfInputs = 100
                , validateSelection = noValidation
                , utxoInputs = [12,20,17]
                , txOutputs = [40,1,1,1]
                })

        coinSelectionUnitTest largestFirst
            "UTxO balance sufficient, fragmented enough, but single output \
            \depletes all UTxO entries"
            (Left ErrUxtoFullyDepleted)
            (CoinSelectionFixture
                { maxNumOfInputs = 100
                , validateSelection = noValidation
                , utxoInputs = [12,20,17]
                , txOutputs = [40, 1]
                })

        coinSelectionUnitTest largestFirst
            "UTxO balance sufficient, fragmented enough, but single output \
            \depletes all UTxO entries"
            (Left ErrUxtoFullyDepleted)
            (CoinSelectionFixture
                { maxNumOfInputs = 100
                , validateSelection = noValidation
                , utxoInputs = [20,20,10,5]
                , txOutputs = [41, 6]
                })

        coinSelectionUnitTest largestFirst
            "UTxO balance sufficient, fragmented enough, but maximum input \
            \count exceeded"
            (Left $ ErrMaximumInputCountExceeded 9)
            (CoinSelectionFixture
                { maxNumOfInputs = 9
                , validateSelection = noValidation
                , utxoInputs = replicate 100 1
                , txOutputs = replicate 100 1
                })

        coinSelectionUnitTest largestFirst
            "UTxO balance sufficient, fragmented enough, but maximum input \
            \count exceeded"
            (Left $ ErrMaximumInputCountExceeded 9)
            (CoinSelectionFixture
                { maxNumOfInputs = 9
                , validateSelection = noValidation
                , utxoInputs = replicate 100 1
                , txOutputs = replicate 10 10
                })

        coinSelectionUnitTest largestFirst
            "UTxO balance sufficient, fragmented enough, but maximum input \
            \count exceeded"
            (Left $ ErrMaximumInputCountExceeded 2)
            (CoinSelectionFixture
                { maxNumOfInputs = 2
                , validateSelection = noValidation
                , utxoInputs = [1,2,10,6,5]
                , txOutputs = [11, 1]
                })

        coinSelectionUnitTest largestFirst
            "Custom validation test fails"
            (Left $ ErrInvalidSelection ErrValidation)
            (CoinSelectionFixture
                { maxNumOfInputs = 100
                , validateSelection = alwaysFail
                , utxoInputs = [1,1]
                , txOutputs = [2]
                })

    describe "Coin selection: largest-first algorithm: properties" $ do

        it "forall (UTxO, NonEmpty TxOut), there's at least as many selected \
            \inputs as there are requested outputs"
            (property $ propAtLeast @TxIn @Address)
        it "forall (UTxO, NonEmpty TxOut), for all selected input, there's no \
            \bigger input in the UTxO that is not already in the selected \
            \inputs"
            (property $ propInputDecreasingOrder @TxIn @Address)

--------------------------------------------------------------------------------
-- Properties
--------------------------------------------------------------------------------

propAtLeast
    :: (Ord i, Ord o)
    => CoinSelProp i o
    -> Property
propAtLeast (CoinSelProp utxo txOuts) =
    isRight selection ==> let Right (s,_) = selection in prop s
  where
    prop (CoinSelection inps _ _) =
        length inps `shouldSatisfy` (>= length txOuts)
    selection = runIdentity $ runExceptT $ selectCoins
        largestFirst (CoinSelectionOptions (const 100) noValidation) utxo txOuts

propInputDecreasingOrder
    :: (Ord i, Ord o)
    => CoinSelProp i o
    -> Property
propInputDecreasingOrder (CoinSelProp utxo txOuts) =
    isRight selection ==> let Right (s,_) = selection in prop s
  where
    prop (CoinSelection inps _ _) =
        let
            utxo' = (Map.toList . getCoinMap) $ utxo `excluding`
                Set.fromList (entryKey <$> coinMapToList inps)
        in unless (L.null utxo') $
            (getExtremumValue L.minimum (entryValue <$> coinMapToList inps))
            `shouldSatisfy`
            (>= (getExtremumValue L.maximum (snd <$> utxo')))
    getExtremumValue f = f . map getCoin
    selection = runIdentity $ runExceptT $ selectCoins largestFirst
        (CoinSelectionOptions (const 100) noValidation) utxo txOuts
