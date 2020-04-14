{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.CoinSelectionSpec
    ( spec

    -- * Export used to test various coin selection implementations
    , CoinSelectionFixture(..)
    , CoinSelectionResult(..)
    , CoinSelProp(..)
    , ErrValidation(..)
    , coinSelectionUnitTest
    , noValidation
    , alwaysFail
    ) where

-- | This module contains shared functionality for coin selection tests.
--
-- Coin selection algorithms share a common interface, and therefore it makes
-- sense for them to also share arbitrary instances and tests.

import Prelude

import Cardano.CoinSelection
    ( Coin (..)
    , CoinMap (..)
    , CoinMapEntry (..)
    , CoinSelection (..)
    , CoinSelectionAlgorithm (..)
    , CoinSelectionError (..)
    , CoinSelectionOptions (..)
    , coinMapFromList
    , coinMapToList
    , coinMapValue
    , sumChange
    , sumInputs
    , sumOutputs
    )
import Cardano.Test.Utilities
    ( Address (..), Hash (..), ShowFmt (..), TxIn (..) )
import Control.Monad.Trans.Except
    ( runExceptT )
import Data.List.NonEmpty
    ( NonEmpty (..) )
import Data.Maybe
    ( catMaybes )
import Data.Word
    ( Word64, Word8 )
import Fmt
    ( Buildable (..), blockListF, nameF )
import Test.Hspec
    ( Spec, SpecWith, describe, it, shouldBe )
import Test.QuickCheck
    ( Arbitrary (..)
    , Confidence (..)
    , Gen
    , NonEmptyList (..)
    , Property
    , arbitraryBoundedIntegral
    , checkCoverage
    , checkCoverageWith
    , choose
    , cover
    , elements
    , generate
    , genericShrink
    , oneof
    , property
    , scale
    , vectorOf
    )
import Test.QuickCheck.Monadic
    ( monadicIO )
import Test.Vector.Shuffle
    ( shuffle )

import qualified Data.ByteString as BS
import qualified Data.List as L
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Test.QuickCheck.Monadic as QC

spec :: Spec
spec = do
    describe "CoinMap properties" $ do
        it "CoinMap coverage is adequate" $
            checkCoverage $ prop_CoinMap_coverage @Int
        it "coinMapFromList preserves total value" $
            checkCoverage $ prop_coinMapFromList_preservesValue @Int
        it "coinMapToList preserves total value" $
            checkCoverage $ prop_coinMapToList_preservesValue @Int
        it "coinMapFromList . coinMapToList = id" $
            checkCoverage $ prop_coinMapToList_coinMapFromList @Int
        it "coinMapToList order deterministic" $
            checkCoverageWith lowerConfidence $
                prop_coinMapToList_orderDeterministic @Int

    describe "CoinSelection properties" $ do
        it "monoidal append preserves keys" $
            checkCoverage $ prop_coinSelection_mappendPreservesKeys @Int @Int
        it "monoidal append preserves value" $
            checkCoverage $ prop_coinSelection_mappendPreservesValue @Int @Int

  where
    lowerConfidence :: Confidence
    lowerConfidence = Confidence (10^(6 :: Integer)) 0.75

--------------------------------------------------------------------------------
-- Properties
--------------------------------------------------------------------------------

prop_CoinMap_coverage
    :: CoinMap u
    -> Property
prop_CoinMap_coverage m = property
    $ cover 10 (null m)
        "coin map is empty"
    $ cover 10 (length m == 1)
        "coin map has one entry"
    $ cover 10 (length m >= 2)
        "coin map has multiple entries"
    $ cover 10 (1 == length (Set.fromList $ entryValue <$> coinMapToList m))
        "coin map has one unique value"
    $ cover 10 (1 < length (Set.fromList $ entryValue <$> coinMapToList m))
        "coin map has several unique values"
    True

prop_coinMapFromList_preservesValue
    :: Ord u
    => [CoinMapEntry u]
    -> Property
prop_coinMapFromList_preservesValue entries = property $
    mconcat (entryValue <$> entries)
        `shouldBe` coinMapValue (coinMapFromList entries)

prop_coinMapToList_preservesValue
    :: CoinMap u
    -> Property
prop_coinMapToList_preservesValue m = property $
    mconcat (entryValue <$> coinMapToList m)
        `shouldBe` coinMapValue m

prop_coinMapToList_coinMapFromList
    :: (Ord u, Show u)
    => CoinMap u
    -> Property
prop_coinMapToList_coinMapFromList m = property $
    coinMapFromList (coinMapToList m)
        `shouldBe` m

prop_coinMapToList_orderDeterministic
    :: Ord u => CoinMap u -> Property
prop_coinMapToList_orderDeterministic u = monadicIO $ QC.run $ do
    let list0 = coinMapToList u
    list1 <- shuffle list0
    return $
        cover 10 (list0 /= list1) "shuffled" $
        list0 == coinMapToList (coinMapFromList list1)

prop_coinSelection_mappendPreservesKeys
    :: (Ord i, Ord o, Show i, Show o)
    => CoinSelection i o
    -> CoinSelection i o
    -> Property
prop_coinSelection_mappendPreservesKeys s1 s2 = property $ do
    Map.keysSet (unCoinMap $ inputs $ s1 <> s2)
        `shouldBe`
        Map.keysSet (unCoinMap $ inputs s1)
        `Set.union`
        Map.keysSet (unCoinMap $ inputs s2)
    Map.keysSet (unCoinMap $ outputs $ s1 <> s2)
        `shouldBe`
        Map.keysSet (unCoinMap $ outputs s1)
        `Set.union`
        Map.keysSet (unCoinMap $ outputs s2)

prop_coinSelection_mappendPreservesValue
    :: (Ord i, Ord o)
    => CoinSelection i o
    -> CoinSelection i o
    -> Property
prop_coinSelection_mappendPreservesValue s1 s2 = property $ do
    sumInputs  s1 <> sumInputs  s2 `shouldBe` sumInputs  (s1 <> s2)
    sumOutputs s1 <> sumOutputs s2 `shouldBe` sumOutputs (s1 <> s2)
    sumChange  s1 <> sumChange  s2 `shouldBe` sumChange  (s1 <> s2)
    change     s1 <> change     s2 `shouldBe` change     (s1 <> s2)

--------------------------------------------------------------------------------
-- Coin Selection - Unit Tests
--------------------------------------------------------------------------------

-- | Data for running
data CoinSelProp i o = CoinSelProp
    { csUtxO :: CoinMap i
        -- ^ Available UTxO for the selection
    , csOuts :: CoinMap o
        -- ^ Requested outputs for the payment
    } deriving Show

instance (Buildable i, Buildable o) => Buildable (CoinSelProp i o) where
    build (CoinSelProp utxo outs) = mempty
        <> nameF "utxo" (blockListF $ coinMapToList utxo)
        <> nameF "outs" (blockListF $ coinMapToList outs)

-- | A fixture for testing the coin selection
data CoinSelectionFixture i o = CoinSelectionFixture
    { maxNumOfInputs :: Word8
        -- ^ Maximum number of inputs that can be selected
    , validateSelection :: CoinSelection i o -> Either ErrValidation ()
        -- ^ A extra validation function on the resulting selection
    , utxoInputs :: [Word64]
        -- ^ Value (in Lovelace) & number of available coins in the UTxO
    , txOutputs :: [Word64]
        -- ^ Value (in Lovelace) & number of requested outputs
    }

-- | A dummy error for testing extra validation
data ErrValidation = ErrValidation deriving (Eq, Show)

-- | Smart constructor for the validation function that always succeeds.
noValidation :: CoinSelection i o -> Either ErrValidation ()
noValidation = const (Right ())

-- | Smart constructor for the validation function that always fails.
alwaysFail :: CoinSelection i o -> Either ErrValidation ()
alwaysFail = const (Left ErrValidation)

-- | Testing-friendly format for 'CoinSelection' results of unit tests.
data CoinSelectionResult = CoinSelectionResult
    { rsInputs :: [Word64]
    , rsChange :: [Word64]
    , rsOutputs :: [Word64]
    } deriving (Eq, Show)

sortCoinSelectionResult :: CoinSelectionResult -> CoinSelectionResult
sortCoinSelectionResult (CoinSelectionResult is cs os) =
    CoinSelectionResult (L.sort is) (L.sort cs) (L.sort os)

-- | Generate a 'UTxO' and 'TxOut' matching the given 'Fixture', and perform
-- the given coin selection on it.
coinSelectionUnitTest
    :: CoinSelectionAlgorithm TxIn Address IO ErrValidation
    -> String
    -> Either (CoinSelectionError ErrValidation) CoinSelectionResult
    -> CoinSelectionFixture TxIn Address
    -> SpecWith ()
coinSelectionUnitTest alg lbl expected (CoinSelectionFixture n fn utxoF outsF) =
    it title $ do
        (utxo,txOuts) <- setup
        result <- runExceptT $ do
            (CoinSelection inps outs chngs, _) <-
                selectCoins alg (CoinSelectionOptions (const n) fn) utxo txOuts
            return $ CoinSelectionResult
                { rsInputs = unCoin . entryValue <$> coinMapToList inps
                , rsChange = unCoin <$> chngs
                , rsOutputs = unCoin . entryValue <$> coinMapToList outs
                }
        fmap sortCoinSelectionResult result
            `shouldBe` fmap sortCoinSelectionResult expected
  where
    title :: String
    title = mempty
        <> if null lbl then "" else lbl <> ":\n\t"
        <> "max=" <> show n
        <> ", UTxO=" <> show utxoF
        <> ", Output=" <> show outsF
        <> " --> " <> show (rsInputs <$> expected)

    setup :: IO (CoinMap TxIn, CoinMap Address)
    setup = do
        utxo <- generate (genUTxO utxoF)
        outs <- generate (genOutputs outsF)
        pure (utxo, outs)

--------------------------------------------------------------------------------
-- Arbitrary Instances
--------------------------------------------------------------------------------

deriving instance Arbitrary a => Arbitrary (ShowFmt a)

instance (Arbitrary i, Arbitrary o, Ord i, Ord o) =>
    Arbitrary (CoinSelection i o)
  where
    arbitrary = CoinSelection
        <$> arbitrary
        <*> arbitrary
        <*> arbitrary
    shrink = genericShrink

instance Arbitrary (CoinSelectionOptions i o e) where
    arbitrary = do
        -- NOTE Functions have to be decreasing functions
        fn <- elements
            [ (maxBound -)
            , \x ->
                if x > maxBound `div` 2
                    then maxBound
                    else maxBound - (2 * x)
            , const 42
            ]
        pure $ CoinSelectionOptions fn (const (pure ()))

instance Show (CoinSelectionOptions i o e) where
    show _ = "CoinSelectionOptions"

instance Arbitrary a => Arbitrary (NonEmpty a) where
    shrink xs = catMaybes (NE.nonEmpty <$> shrink (NE.toList xs))
    arbitrary = do
        n <- choose (1, 10)
        NE.fromList <$> vectorOf n arbitrary

instance (Arbitrary i, Arbitrary o, Ord i, Ord o) =>
    Arbitrary (CoinSelProp i o)
  where
    shrink (CoinSelProp utxo outs) = uncurry CoinSelProp <$> zip
        (shrink utxo)
        (coinMapFromList <$> filter (not . null) (shrink (coinMapToList outs)))
    arbitrary = CoinSelProp
        <$> (coinMapFromList . getNonEmpty <$> arbitrary)
        <*> (coinMapFromList . getNonEmpty <$> arbitrary)

instance Arbitrary Address where
    shrink _ = []
    arbitrary = do
        bytes <- BS.pack <$> vectorOf 8 arbitraryBoundedIntegral
        pure $ Address bytes

instance Arbitrary Coin where
    -- No Shrinking
    arbitrary = Coin <$> choose (1, 100000)

instance Arbitrary TxIn where
    -- No Shrinking
    arbitrary = TxIn
        <$> arbitrary
        <*> scale (`mod` 3) arbitrary -- No need for a high indexes

instance Arbitrary (Hash "Tx") where
    -- No Shrinking
    arbitrary = do
        wds <- vectorOf 10 arbitrary :: Gen [Word8]
        let bs = BS.pack wds
        pure $ Hash bs

instance Arbitrary a => Arbitrary (CoinMapEntry a) where
    -- No Shrinking
    arbitrary = CoinMapEntry
        <$> arbitrary
        <*> arbitrary

instance (Arbitrary a, Ord a) => Arbitrary (CoinMap a) where
    shrink (CoinMap m) = CoinMap <$> shrink m
    arbitrary = do
        n <- oneof
            [ pure 0
            , pure 1
            , choose (2, 100)
            ]
        entries <- zip
            <$> vectorOf n arbitrary
            <*> vectorOf n arbitrary
        return $ CoinMap $ Map.fromList entries

genUTxO :: [Word64] -> Gen (CoinMap TxIn)
genUTxO coins = do
    let n = length coins
    inps <- vectorOf n arbitrary
    return $ CoinMap $ Map.fromList $ zip inps (Coin <$> coins)

genOutputs :: [Word64] -> Gen (CoinMap Address)
genOutputs coins = do
    let n = length coins
    outs <- vectorOf n arbitrary
    return $ coinMapFromList $ zipWith CoinMapEntry outs (map Coin coins)