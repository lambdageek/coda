{-# language ConstraintKinds #-}
{-# language DeriveAnyClass #-}
{-# language BangPatterns #-}
{-# language DeriveDataTypeable #-}
{-# language DeriveGeneric #-}
{-# language FlexibleContexts #-}
{-# language LambdaCase #-}
{-# language PatternGuards #-}
{-# language PatternSynonyms #-}
{-# language RankNTypes #-}
{-# language RoleAnnotations #-}
{-# language ScopedTypeVariables #-}
{-# language UndecidableInstances #-}
{-# language StrictData #-}
-- {-# language Strict #-}
{-# language ViewPatterns #-}
{-# options_ghc -funbox-strict-fields #-}

module Data.BDD
  ( -- * ROBDDs
    BDD(Zero, One, BDD, BDD_, ROBDD)
    -- * combinators
  , ite, neg, implies, nand
    -- * variables
  , var -- bit
    -- * booleans
  , bool
  , liftB
  , liftB2
    -- * quantification
  , forall
  , exists
  , unique
    -- * functions of two arguments
  , Fun(..), fun, table
    -- * memo management
  , reifyCache, Cache, Cached, cacheSizes
  , with
  , copy_     -- copy without relabeling
  , copy      -- substitute and copy
  , copy'     -- substitute and copy (in the same cache)
  , copyMono  -- relabel monotonically and copy
  , copyMono' -- relabel monotonically and copy (in the same cache)
  , copyStrictMono  -- relabel strictly monotonically and copy
  , copyStrictMono' -- relabel strictly monotonically and copy (in the same cache)
  , gite, gtable, gliftB2
    -- * satisfaction
  , sat
    -- * tautology checking
  , Constant(..)
  , constant
  , itec
    -- ** enumerating solutions
  , Binding(..)
  , sats
    -- * observations
  , Data.BDD.size
  , node
  , Node(..)
  , vars
  , showBDD
    -- * internals
  , polarize
  ) where

import Control.Applicative as A
import Control.Lens
import Control.Monad.Trans.State.Strict
import Data.Bimap as Bimap
import Data.Bits as Bits
import Data.Coerce
import Data.Data
import Data.Hashable
import Data.HashMap.Strict as HashMap
import Data.IORef
import Data.Reflection
import Data.Semigroup
import Data.Set as Set
-- import Debug.Trace
import GHC.Arr
import GHC.Generics
import System.IO.Unsafe (unsafePerformIO)
import Prelude hiding (or, and)

type Var = Int

type NodeId = Id

data Node = F | T | Node NodeId Var Node Node
  deriving (Show,Data,Generic)

instance Eq Node where
  F == F = True
  T == T = True
  Node i _ _ _ == Node j _ _ _ = i == j
  _ == _ = False

(==!) :: BDD s -> BDD s -> Bool
D F ==! D T = True
D T ==! D F = True
D (Node i _ _ _) ==! D (Node j _ _ _) = i == -j
_ ==! _ = False

instance Ord Node where
  F `compare` F = EQ
  F `compare` _ = LT
  T `compare` F = GT
  T `compare` T = EQ
  T `compare` Node{} = LT
  Node i _ _ _ `compare` Node j _ _ _ = compare i j
  Node{} `compare` _ = GT

instance Hashable Node where
  hash F = 0
  hash T = maxBound
  hash (Node i _ _ _) = i

data Key = Key Var Node Node
  deriving (Eq,Ord,Show,Data,Generic,Hashable)

data ITE = ITE Node Node Node
  deriving (Eq,Ord,Show,Data,Generic,Hashable)

newtype BDD s = D Node
  deriving (Eq,Ord,Show,Data,Generic,Hashable)

node :: BDD s -> Node
node (D n) = n

type Memo = HashMap ITE Node -- cached ite results

type ConstantMemo = HashMap ITE Constant

data Constant = FalseConstant | NonConstant | TrueConstant

type DAG = Bimap Key

data Cache = Cache
  { getCache :: IORef DAG
  , getMemo :: IORef Memo
  , getConstantMemo :: IORef ConstantMemo
  } deriving Eq

type Cached s = Reifies s Cache

modifyCache :: forall s r proxy. Cached s => proxy s -> (DAG -> (DAG, r)) -> IO r
modifyCache _ = atomicModifyIORef' $ getCache $ reflect (Proxy :: Proxy s)

-- this node is allowed as a child of a 'hi' branch for a BDD node
okhi :: Node -> Bool
okhi F = False
okhi (Node i _ _ _) = i > 0
okhi _ = True

nodeId :: forall s proxy. Cached s => proxy s -> Var -> Node -> Node -> NodeId
nodeId _ !v !l !r = unsafePerformIO $ modifyCache (Proxy :: Proxy s) $ Bimap.insertR $ Key v l r

bdd :: forall s. Cached s => Var -> BDD s -> BDD s -> BDD s
bdd !v (D l) (D r)
  | l == r = D l
  | okhi r = D (Node (nodeId (Proxy :: Proxy s) v l r) v l r)
  | nl <- negNode l
  , nr <- negNode r = D (Node (- nodeId (Proxy :: Proxy s) v nl nr) v nl nr)

--------------------------------------------------------------------------------
-- safe user accessible BDD constructors:
--------------------------------------------------------------------------------

-- present only positive forms through the "BDD" constructor so users don't need to understand the negation optimization
polarizeNode :: Int -> Node -> Node
polarizeNode !i !s
  | i > 0     = s
  | otherwise = negNode s

polarize :: Int -> BDD s -> BDD s
polarize !i !(D m) = D $ polarizeNode i m

-- bidirectional matching and construction using the tape, censoring node ids
pattern BDD :: Cached s => Var -> BDD s -> BDD s -> BDD s
pattern BDD v l r <- D (Node i v (D . polarizeNode i -> l) (D . polarizeNode i -> r)) where
  BDD v l r = bdd v l r

-- read only access to the node, hiding negation (useful when the cache is no longer around)
pattern BDD_ :: Var -> BDD s -> BDD s -> BDD s
pattern BDD_ v l r <- D (Node i v (D . polarizeNode i -> l) (D . polarizeNode i -> r))

-- read only access to node ids, NB: this exposes the negation optimization
pattern ROBDD :: NodeId -> Var -> BDD s -> BDD s -> BDD s
pattern ROBDD i v l r <- D (Node i v (D -> l) (D -> r))

pattern Zero :: BDD s
pattern Zero = D F

pattern One :: BDD s
pattern One = D T

{-# complete Zero, One, BDD #-}
{-# complete Zero, One, BDD_ #-}
{-# complete Zero, One, ROBDD #-}
{-# complete D #-}

-- | /O(1)/, see https://www.ece.cmu.edu/~ee760/760docs/lec03.pdf Optimization: Negation Arcs
--
-- Invariants for negation arcs:
--
-- 1. no double negation (forced by only negating node ids)
--
-- 2. no negated high pointers (see hi check)
--
-- 3. no negated constants (by design of neg)
--
-- 4. no high pointers to 0
--
-- Gives constant time negation and 2x space improvement

neg :: BDD s -> BDD s
neg (D x) = D (negNode x)

negNode :: Node -> Node
negNode F = T
negNode T = F
negNode (Node i v l r) = Node (-i) v l r

reifyCache :: (forall s. Cached s => Proxy s -> r) -> r
reifyCache f = unsafePerformIO $ do
  r <- newIORef Bimap.empty
  m <- newIORef HashMap.empty
  n <- newIORef HashMap.empty
  return $ reify (Cache r m n) f

with :: forall f r. (forall s. Cached s => f s) -> (forall s. f s -> r) -> r
with f k = reifyCache $ \(Proxy :: Proxy s) -> k (f :: f s)

-- root decision variable
root :: BDD s -> Var
root = \case
  D (Node _ v _ _) -> v
  _ -> maxBound

-- Shannon decomposition assuming u >= v
shannon :: Var -> BDD s -> (BDD s, BDD s)
shannon !u (ROBDD i v l r) | u == v = (polarize i l, polarize i r) -- present results in positive form
shannon _ n = (n, n)

-- Shannon decomposition assuming u >= v with a strictly monotone function used to shift the root
gshannon :: (Var -> Var) -> Var -> BDD s -> (BDD s, BDD s)
gshannon f !u (ROBDD i v l r) | u == f v = (polarize i l, polarize i r) -- present results in positive form
gshannon _ _ n = (n, n)

iteid :: BDD s -> Int
iteid (D (Node i _ _ _)) = abs i
iteid _ = minBound

itegt :: BDD s -> BDD s -> Bool
itegt f g = case compare (root f) (root g) of
  LT -> False
  EQ -> iteid f > iteid g
  GT -> True

isNeg :: BDD s -> Bool
isNeg (D (Node i _ _ _)) = i < 0
isNeg (D T) = False
isNeg (D F) = True

-- normalize arguments for if then else exploiting symmetries, no cache required
normalized :: BDD s -> BDD s -> BDD s -> (Bool, BDD s, BDD s, BDD s)
normalized = go where
  -- redundant g
  go f g h
    | f ==  g   = go1 f One h  -- ite f f h  = ite f T h
    | f ==! g   = go1 f Zero h -- ite f ~f h = ite f F h
    | otherwise = go1 f g h

  -- redundant h
  go1 f g h
    | f ==  h   = go2 f g Zero -- ite f g f  = ite f g F
    | f ==! h   = go2 f g One  -- ite f g ~f = ite f g T
    | otherwise = go2 f g h

  -- minimize f against h if we can
  go2 f One h  | itegt f h = go3 h One f              -- ite f T h = f | h = h | f = ite h T f
  go2 f Zero h | itegt f h = go3 (neg h) Zero (neg f) -- ite f F h = h & ~f = ite h ~f F = ite ~h F ~f
  go2 f g h                = go3 f g h

  -- minimize f against g if we can
  go3 f g Zero | itegt f g = go4 g f Zero            -- ite f g F = f & g = g & f = ite g f F
  go3 f g One  | itegt f g = go4 (neg g) (neg f) One -- ite f g T = f & g | ~f = ite g T ~f = ite ~g ~f T
  go3 f g h                = go4 f g h

  -- symmetric difference is symmetric, minimize f
  go4 f g h
    | g ==! h, itegt f g = go5 g f (neg f)           -- ite f g ~g = (f&g)|(~f&~g) = ite g f ~f
    | otherwise          = go5 f g h

  -- ite f g h = ite ~f h g, ensure f is positive
  go5 f g h
    | isNeg f = go6 (neg f) h g
    | otherwise = go6 f g h

  -- ite f g h = ~ite f ~g ~h, ensure g is positive
  go6 f g h
    | isNeg g   = (False, f, neg g, neg h)
    | otherwise = (True,  f, g,     h    )
{-# inline normalized #-}

ite :: forall s. Cached s => BDD s -> BDD s -> BDD s -> BDD s
ite f0 g0 h0 = unsafePerformIO $ go f0 g0 h0 where
  mr = getMemo $ reflect (Proxy :: Proxy s)
  tweak True x = x
  tweak False x = neg x
  go :: BDD s -> BDD s -> BDD s -> IO (BDD s)
  go f1 g1 h1 = case normalized f1 g1 h1 of
    (i, One,  g,   _   ) -> pure (tweak i g)
    (i, Zero, _,   h   ) -> pure (tweak i h)
    (i, f,    One, Zero) -> pure (tweak i f)
    (i, f,    g,   h   )
      | g == h -> pure (tweak i g)
      | k <- coerce ITE f g h -> readIORef mr >>= \m -> case HashMap.lookup k m of
      Just r -> pure $ tweak i $ D r
      Nothing
        | v <- root f `min` root g `min` root h -- TODO: can we prove this is just root f after normalize?
        , (f',f'') <- shannon v f
        , (g',g'') <- shannon v g
        , (h',h'') <- shannon v h -> do
          r <- bdd v <$> go f' g' h' <*> go f'' g'' h''
          tweak i r <$ atomicModifyIORef' mr (\m' -> (HashMap.insert k (node r) m', ()))

instance Semigroup Constant where
  FalseConstant <> FalseConstant = FalseConstant
  TrueConstant <> TrueConstant = TrueConstant
  _ <> _ = NonConstant

-- |
-- @
-- itec f g h = constant (ite f g h)
-- @
--
-- but it can be implemented much more efficiently
itec :: forall s. Cached s => BDD s -> BDD s -> BDD s -> Constant
itec f0 g0 h0 = unsafePerformIO $ go f0 g0 h0 where
  mr = getConstantMemo $ reflect (Proxy :: Proxy s)
  tweak True x = x
  tweak False FalseConstant = TrueConstant
  tweak False TrueConstant = FalseConstant
  tweak False NonConstant = NonConstant
  cont :: ITE -> Constant -> IO Constant
  cont k r = r <$ atomicModifyIORef' mr (\m' -> (HashMap.insert k r m', ()))
  go :: BDD s -> BDD s -> BDD s -> IO Constant
  go f1 g1 h1 = case normalized f1 g1 h1 of
    (i,One,g,_)    -> pure $ tweak i $ constant g
    (i,Zero,_,h)   -> pure $ tweak i $ constant h
    (i,f,One,Zero) -> pure $ tweak i $ constant f
    (i,f,g,h)
      | g == h -> pure $ tweak i $ constant g
      | k <- coerce ITE f g h -> readIORef mr >>= \m -> case HashMap.lookup k m of
      Just r -> pure $ tweak i r
      Nothing
        | v <- root f `min` root g `min` root h
        , (f',f'') <- shannon v f
        , (g',g'') <- shannon v g
        , (h',h'') <- shannon v h -> go f' g' h' >>= \case
          NonConstant -> cont k NonConstant
          x           -> go f'' g'' h'' >>= \case
            NonConstant -> cont k NonConstant
            y           -> tweak i <$> cont k (x <> y)

-- perform an if then else using strictly monotone relabeling scheme
gite
  :: forall s t u v. Cached v
  => (Var -> Var) -- strictly monotone relabeling for f
  -> (Var -> Var) -- strictly monotone relabeling for g
  -> (Var -> Var) -- strictly monotone relabeling for h
  -> BDD s
  -> BDD t
  -> BDD u
  -> BDD v
gite vf vg vh f0 g0 h0 = evalState (go f0 g0 h0) mempty where
  go :: BDD s -> BDD t -> BDD u -> State (HashMap NodeId (BDD v), HashMap NodeId (BDD v), HashMap NodeId (BDD v), HashMap ITE (BDD v)) (BDD v)
  -- we don't get the nice symmetries above
  go One g _    = zoom _2 $ copyStrictMonoM vg g
  go Zero _ h   = zoom _3 $ copyStrictMonoM vh h
  go f One Zero = zoom _1 $ copyStrictMonoM vf f
  go f g h
    | k <- coerce ITE f g h = use (_4.at k) >>= \case
      Just r -> pure r
      Nothing
        | v <- vf (root f) `min` vg (root g) `min` vh (root h)
        , (f',f'') <- gshannon vf v f
        , (g',g'') <- gshannon vg v g
        , (h',h'') <- gshannon vh v h -> do
          r <- bdd v <$> go f' g' h' <*> go f'' g'' h''
          r <$ (_4.at k ?= r)

-- check satisfiability
sat :: BDD s -> Bool
sat Zero = False
sat _ = True

-- check for tautology
constant :: BDD s -> Constant
constant One = TrueConstant
constant Zero = FalseConstant
constant _ = NonConstant

data Binding = Var := Bool deriving (Eq,Ord,Show,Read,Data,Generic,Hashable)

-- find any or all satisfying variable assignments by choosing Seq or Maybe
sats :: Alternative m => BDD s -> m [Binding]
sats !n0 = evalState (go n0) HashMap.empty where
  go Zero = pure A.empty
  go One = pure (pure [])
  go (ROBDD i v (polarize i -> l) (polarize i -> r)) = gets (HashMap.lookup i) >>= \case
    Just x  -> pure x
    Nothing -> do
      x <- go l
      y <- go r
      let result = fmap ((v := False):) x <|> fmap ((v := True):) y
      result <$ modify (HashMap.insert i result)

-- # of distinct nodes present in the BDD
size :: BDD s -> Int
size !(D n0) = Set.size (go n0 Set.empty) where
  go (Node (abs -> i) _ l r) s | Set.notMember i s = go l $ go r $ Set.insert i s
  go _ s = s

cacheSizes :: forall s proxy. Cached s => proxy s -> IO (Int,Int,Int)
cacheSizes _ = case reflect (Proxy :: Proxy s) of
  Cache c m n -> (\x y z -> (Bimap.size x, HashMap.size y, HashMap.size z)) <$> readIORef c <*> readIORef m <*> readIORef n

quantify :: Cached s => (BDD s -> BDD s -> BDD s) -> Set Var -> BDD s -> BDD s
quantify q !vs !n0 = evalState (go n0) HashMap.empty where
  go (ROBDD i v (polarize i -> l) (polarize i -> r)) = gets (HashMap.lookup i) >>= \case
    Just z -> pure z
    Nothing -> do
      z <- (if Set.member v vs then q else bdd v) <$> go l <*> go r
      z <$ modify (HashMap.insert i z)
  go x = pure x

forall :: Cached s => Set Var -> BDD s -> BDD s
forall = quantify (.&.)

exists :: Cached s => Set Var -> BDD s -> BDD s
exists = quantify (.|.)

unique :: Cached s => Set Var -> BDD s -> BDD s
unique = quantify xor

-- lift a unary boolean function
liftB :: (Bool -> Bool) -> BDD s -> BDD s
liftB f !s
  | f False   = if f True then One else neg s
  | otherwise = if f True then s else Zero

-- | all two argument functions enumerated by truth tables
data Fun = TNever | TAnd | TGt | TF | TLt | TG | TXor | TOr | TNor | TXnor | TG' | TGe | TF' | TLe | TNand | TAlways
  deriving (Eq,Ord,Show,Read,Ix,Enum,Bounded,Data,Generic)

instance Bits Fun where
  (.&.) f g    = toEnum (fromEnum f .&. fromEnum g)
  (.|.) f g    = toEnum (fromEnum f .|. fromEnum g)
  xor f g      = toEnum (fromEnum f `xor` fromEnum g)
  complement f = toEnum (Bits.complement (fromEnum f) .&. 15)
  shift x i = toEnum (shift (fromEnum x) i .&. 15)
  rotateL (fromEnum -> x) i = toEnum $ (shiftL x i .|. shiftR x (4 - i)) .&. 15
  rotateR (fromEnum -> x) i = toEnum $ (shiftR x i .|. shiftL x (4 - i)) .&. 15
  bit i = toEnum (bit i .&. 15)
  testBit = testBit . fromEnum
  setBit x i = toEnum (setBit (fromEnum x) i .&. 15)
  clearBit x i = toEnum (clearBit (fromEnum x) i .&. 15)
  bitSizeMaybe _ = Just 4
  bitSize _ = 4
  isSigned _ = False
  zeroBits = TNever
  popCount = popCount . fromEnum

instance FiniteBits Fun where
  finiteBitSize _ = 4

-- enumerate as a two argument boolean function
fun :: (Bool -> Bool -> Bool) -> Fun
fun f = toEnum
  $ 8 * fromEnum (f False False)
  + 4 * fromEnum (f False True)
  + 2 * fromEnum (f True False)
  +     fromEnum (f True True)

table :: Cached s => Fun -> BDD s -> BDD s -> BDD s
table TNever  _ _ = Zero               -- false
table TAnd    f g = ite f g Zero       -- f && g
table TGt     f g = ite f (neg g) Zero -- f > g
table TF      f _ = f                  -- f
table TLt     f g = ite f Zero g       -- f < g
table TG      _ g = g                  -- g
table TXor    f g = ite f (neg g) g    -- xor f g
table TOr     f g = ite f One g        -- f || g
table TNor    f g = ite f Zero (neg g) -- nor f g
table TXnor   f g = ite f g (neg g)    -- xnor f g
table TG'     _ g = neg g              -- neg g
table TGe     f g = ite f One (neg g)  -- f >= g
table TF'     f _ = neg f              -- neg f
table TLe     f g = ite f g One        -- f <= g
table TNand   f g = ite f (neg g) One  -- nand f g
table TAlways _ _ = One                -- true

-- | lift boolean functions through the table e.g. @liftB2 (&&)@, @liftB2 (<=)@
liftB2 :: Cached s => (Bool -> Bool -> Bool) -> BDD s -> BDD s -> BDD s
liftB2 = table . fun

gtable :: Cached v => Fun -> (Var -> Var) -> (Var -> Var) -> BDD s -> BDD u -> BDD v
gtable m vf vg f g | vh <- id = case m of
  TNever  -> Zero                          -- false
  TAnd    -> gite vf vg vh f g Zero        -- f && g
  TGt     -> gite vf vg vh f (neg g) Zero  -- f > g
  TF      -> copyStrictMono vf f           -- f
  TLt     -> gite vf vh vg f Zero g        -- f < g
  TG      -> copyStrictMono vg g           -- g
  TXor    -> gite vf vg vg f (neg g) g     -- xor f g
  TOr     -> gite vf vh vg f One g         -- f || g
  TNor    -> gite vf vh vg f Zero (neg g)  -- nor f g
  TXnor   -> gite vf vg vg f g (neg g)     -- xnor f g
  TG'     -> copyStrictMono vg (neg g)     -- neg g
  TGe     -> gite vf vh vg f One (neg g)   -- f >= g
  TF'     -> copyStrictMono vf (neg f)     -- neg f
  TLe     -> gite vf vg vh f g One         -- f <= g
  TNand   -> gite vf vg vh f (neg g) One   -- nand f g
  TAlways -> One

gliftB2 :: Cached v => (Bool -> Bool -> Bool) -> (Var -> Var) -> (Var -> Var) -> BDD s -> BDD u -> BDD v
gliftB2 = gtable . fun

implies :: Cached s => BDD s -> BDD s -> BDD s
implies !f !g = ite f One (neg g) -- f >= g

nand :: Cached s => BDD s -> BDD s -> BDD s
nand !f !g = ite f (neg g) One

bool :: Bool -> BDD s
bool False = D F
bool True = D T

var :: Cached s => Var -> BDD s
var v = bdd v Zero One

-- relevant variables
vars :: BDD s -> Set Var
vars (D n0) = go n0 Set.empty  where
  go T s = s
  go F s = s
  go (Node _ v l r) s = Set.insert v (go l (go r s))

-- O(|n|) copy a BDD over to a new tape
copy_ :: Cached s' => BDD s -> BDD s'
copy_ (D n) = evalState (go n) HashMap.empty where
  go (Node i v l r) = gets (HashMap.lookup $ abs i) >>= \case
    Just z -> pure z
    Nothing -> do
      z <- bdd v <$> go (polarizeNode i l) <*> go (polarizeNode i r)
      polarize i z <$ modify (HashMap.insert (abs i) z)
  go x = pure (D x)

-- copy a BDD over to a new tape and performs variable substitution
copy :: Cached s' => (Var -> BDD s') -> BDD s -> BDD s'
copy f !n0 = evalState (go n0) HashMap.empty where
  go Zero = pure Zero
  go One  = pure One
  go (ROBDD i (f -> v) l r) = gets (HashMap.lookup $ abs i) >>= \case
      Just z -> pure (polarize i z)
      Nothing -> do
        z <- ite v <$> go (polarize i l) <*> go (polarize i r)
        polarize i z <$ modify (HashMap.insert (abs i) z)

-- work within one cache
copy' :: Cached s => (Var -> BDD s) -> BDD s -> BDD s
copy' = copy

-- relabel with a strictly monotone increasing function
copyStrictMono :: forall s s'. Cached s' => (Var -> Var) -> BDD s -> BDD s'
copyStrictMono f !n0 = evalState (copyStrictMonoM f n0) HashMap.empty where

-- relabel with a strictly monotone increasing function with a preserved cache
copyStrictMonoM :: forall s s'. Cached s' => (Var -> Var) -> BDD s -> State (HashMap NodeId (BDD s')) (BDD s')
copyStrictMonoM _ Zero = pure Zero
copyStrictMonoM _ One  = pure One
copyStrictMonoM f (ROBDD i (f -> v) l r) = gets (HashMap.lookup $ abs i) >>= \case
    Just z -> pure (polarize i z)
    Nothing -> do
      z <- bdd v <$> copyStrictMonoM f (polarize i l) <*> copyStrictMonoM f (polarize i r)
      polarize i z <$ modify (HashMap.insert (abs i) z)

copyStrictMono' :: Cached s => (Var -> Var) -> BDD s -> BDD s
copyStrictMono' = copyStrictMono

{-
-- create a BDD node that may be related to its _immediate_ children by sharing the same variable
--     v
--    / \         v
--   v   v   =>  / \
--  / \ / \      a d
--  a b c d
bddMono :: Cached s => Var -> BDD s -> BDD s -> BDD s
bddMono v l r = bdd v (fst $ shannon v l) (snd $ shannon v r)
-}

-- relabel with a monotone increasing function
copyMono :: Cached s' => (Var -> Var) -> BDD s -> BDD s'
copyMono f !n0 = evalState (go False maxBound n0) HashMap.empty where
  -- tracks direction and last variable
  go _ _ Zero = pure Zero
  go _ _ One  = pure One
  go b u (ROBDD i (f -> v) l r)
    | u == v = go b u $ polarize i $ if b then l else r -- skip directly rather than common up with bddMono ex post facto
    | otherwise = gets (HashMap.lookup (abs i)) >>= \case
      Just z -> pure $ polarize i z
      Nothing -> do
        z <- bdd v <$> go False v (polarize i l) <*> go True v (polarize i r)
        polarize i z <$ modify (HashMap.insert (abs i) z)

copyMono' :: Cached s => (Var -> Var) -> BDD s -> BDD s
copyMono' = copyMono

showBDD :: BDD s -> String
showBDD !n0 = go (0 :: Int) n0 "" where
  go _ One  = showString "One"
  go _ Zero = showString "Zero"
  go d (BDD_ v l r) = showParen (d>10)
    $ showString "BDD " . showsPrec 11 v
    . showChar ' ' . go 11 l
    . showChar ' ' . go 11 r

-- punning for great good
instance Cached s => Bits (BDD s) where
  (.&.) f g = ite f g Zero
  (.|.) f g = ite f One g
  xor f g = ite f (neg g) g
  complement = neg
  shift b i = copyStrictMono (i+) b
  rotate b i = copyStrictMono (i+) b
  zeroBits = Zero
  bit = var
  setBit b i = copy (\j -> if i == j then One else var i) b
  clearBit b i = copy (\j -> if i == j then Zero else var i) b
  complementBit b i = copy (\j -> if i == j then neg (var j) else var j) b
  testBit = error "BDD.testBit" -- ok, yeah i got nothing
  bitSizeMaybe _ = Nothing
  bitSize = error "BDD.bitSize" -- legacy
  isSigned _ = True
  popCount = error "BDD.popCount"
