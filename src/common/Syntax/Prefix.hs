{-# language DeriveDataTypeable #-}
{-# language DeriveGeneric #-}
{-# language OverloadedStrings #-}

---------------------------------------------------------------------------------
-- |
-- Copyright :  (c) Edward Kmett 2017
-- License   :  BSD-2-Clause OR Apache-2.0
-- Maintainer:  Edward Kmett <ekmett@gmail.com>
-- Stability :  experimental
-- Portability: non-portable
--
---------------------------------------------------------------------------------

module Syntax.Prefix
  ( Prefix(..)
  , joinAndCompare
  , HasPrefix(..)
  ) where

import Data.Char (isSpace)
import Data.Data hiding (Prefix)
import Data.Semigroup
import Data.String
import Data.Text as Text
import GHC.Generics hiding (Prefix)
import Prelude

import Algebra.Zero
import Syntax.FromText

-- | line prefixes form a semigroup with a zero
newtype Prefix = Prefix Text deriving (Eq,Show,Generic,Data)

joinAndCompare :: Prefix -> Prefix -> Either Prefix Ordering
joinAndCompare (Prefix xs) (Prefix ys) = case commonPrefixes xs ys of
    Just (c, l, r) -> cmp c l r
    Nothing        -> cmp "" xs ys
  where
    cmp _ "" "" = Right EQ
    cmp _ "" _  = Right LT
    cmp _ _  "" = Right GT
    cmp c _  _  = Left (Prefix c)

instance Semigroup Prefix where
  Prefix xs <> Prefix ys
    = Prefix $ case commonPrefixes xs ys of
      Just (zs, _, _) -> zs
      Nothing         -> ""

instance SemigroupWithZero Prefix where
  zero = Prefix ""

instance FromText Prefix where
  fromText = Prefix . Text.takeWhile isSpace

instance IsString Prefix where
  fromString = Prefix . pack . Prelude.takeWhile isSpace

class HasPrefix t where
  prefix :: t -> Prefix

instance HasPrefix Prefix where
  prefix = id
