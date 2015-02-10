{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ExistentialQuantification #-}

-- |
-- Module      : Control.Auto.Core
-- Description : Core types, constructors, and utilities.
-- Copyright   : (c) Justin Le 2014
-- License     : MIT
-- Maintainer  : justin@jle.im
-- Stability   : unstable
-- Portability : portable
--
-- This module defines and provides the core types, (smart) constructors,
-- and general utilities used by the 'Auto' library.
--
-- A lot of low-level functionality is provided here which is most likely
-- unnecessary for most applications; many are mostly for internal usage or
-- advanced/fine-grained usage; it also isn't really enough to do many
-- things with, either.  It's recommended that you import "Control.Auto"
-- instead, which re-organizes the more useful parts of this module in
-- addition with useful parts of others to provide a nice packaged entry
-- point.
--
-- For information on how to actually use these types, see
-- "Control.Auto.Tutorial".
--

module Control.Auto.Core (
  -- * Auto
  -- ** Type
    Auto
  , Auto'
  , autoConstr
  , toArb
  -- ** Running
  , stepAuto
  , stepAuto'
  -- ** Serializing
  -- $serializing
  , encodeAuto
  , decodeAuto
  , saveAuto
  , loadAuto
  -- ** Underlying monad
  , hoistA
  , generalizeA
  -- * Auto output
  , Output(..)
  , Output'
  , onOutput
  , onOutRes
  , onOutAuto
  -- * Auto constructors
  -- ** Lifting values and functions
  , mkConst
  , mkConstM
  , mkFunc
  , mkFuncM
  -- ** from State transformers
  , mkState
  , mkState_
  , mkStateM
  , mkStateM_
  , mkState'
  , mkStateM'
  -- ** from Accumulators
  -- *** Result-first
  , mkAccum
  , mkAccum_
  , mkAccumM
  , mkAccumM_
  -- *** Initial accumulator-first
  , mkAccumD
  , mkAccumD_
  , mkAccumMD
  , mkAccumMD_
  -- ** Arbitrary Autos
  , mkAuto
  , mkAuto_
  , mkAutoM
  , mkAutoM_
  -- * Strictness
  , forceSerial
  , forcer
  , seqer
  ) where

import Control.Applicative
import Control.Arrow
import Control.Category
import Control.DeepSeq
import Control.Monad
import Control.Monad.Fix
import Data.ByteString hiding (empty)
import Data.Functor.Identity
import Data.Profunctor
import Data.Semigroup
import Data.Serialize
-- import Data.Typeable
import GHC.Generics
import Prelude hiding        ((.), id)

-- TODO: provde combinators/ability to map over the result or use the
-- result of stepAuto, without ruining the internal constructor structure

-- | The output of a 'stepAuto'.  Contains the "result" value of the
-- stepping ('outRes'), and the "next 'Auto'", 'outAuto'.
--
-- An @'Auto' m a b@ will produce an @'Output' m a b@; when "stepped" with
-- an @a@, the "result" ('outRes') is a @b@.
--
-- Really, you can just think of this as a fancy tuple.
data Output m a b = Output { outRes  :: b             -- ^ Result value of a step
                           , outAuto :: Auto m a b    -- ^ The next 'Auto'
                           } deriving ( Functor
                                      -- , Typeable
                                      , Generic
                                      )

instance Monad m => Applicative (Output m a) where
    pure x                      = Output x (pure x)
    Output fx ft <*> Output x t = Output (fx x) (ft <*> t)

-- | Map two functions onto both fields of an 'Output'.
--
-- If you want to map an @a -> b@ onto both fields (the result and the
-- result of the next Auto), you can use the 'Functor' instance instead.
onOutput :: (b -> b')                     -- ^ function over the result
         -> (Auto m a b -> Auto m a' b')  -- ^ function over the resulting 'Auto'
         -> Output m a b
         -> Output m a' b'
onOutput fx fa (Output x a) = Output (fx x) (fa a)
{-# INLINE onOutput #-}

-- | Map a function onto the 'outAuto of an 'Output', the resulting
-- 'Auto'.  See note on 'onOutRes'.
onOutAuto :: (Auto m a b -> Auto m a' b)  -- ^ function over the resulting 'Auto'
          -> Output m a b
          -> Output m a' b
onOutAuto fa (Output x a) = Output x (fa a)
{-# INLINE onOutAuto #-}

-- | Map a function onto the 'outRes' of an 'Output': the "result" of
-- a 'stepAuto'.
--
-- Useful for completely pointless and probably obfuscating point free code :D
onOutRes :: (b -> b)      -- ^ function over the result
         -> Output m a b
         -> Output m a b
onOutRes fx (Output x a) = Output (fx x) a
{-# INLINE onOutRes #-}



-- | The Auto type.  Basically represents a function containing its own
-- localized internal state.  If you have an @'Auto' a b@, you can "step"
-- it with 'stepAuto' and an @a@, to get a @b@ and a "next 'Auto'".  The
-- @a@ is the input, and the @b@ is the output, and the next 'Auto' is the
-- 'Auto' with updated internal state.
--
-- The "stepping" process can be monadic:
--
-- > stepAuto :: Auto m a b -> a -> m (Output m a b)
--
-- So you can have access to, say, a shared environment using 'Reader' or
-- something like that.
--
-- 'Auto' is mostly useful because of its 'Functor', 'Applicative',
-- 'Category', and 'Arrow' (and Arrow-related) instances.  These allow you
-- to modify, combine, chain, and side-chain Autos in expressive way,
-- allowing you to build up complex ones from combinations of simple,
-- primitive ones.
--
-- TODO: see tutorial
--
-- The 'Auto' also contains information on its own serialization, so you
-- can serialize and re-load the internal state without actually accessing
-- it.
data Auto m a b =           AutoFunc    !(a -> b)
                |           AutoFuncM   !(a -> m b)
                | forall s. AutoState   (Get s, s -> Put) !(a -> s -> (b, s))   !s
                | forall s. AutoStateM  (Get s, s -> Put) !(a -> s -> m (b, s)) !s
                |           AutoArb     (Get (Auto m a b)) Put !(a -> Output m a b)
                |           AutoArbM    (Get (Auto m a b)) Put !(a -> m (Output m a b))

-- data Auto m a b = Auto { _loadAuto :: Get (Auto m a b)
--                        , _saveAuto :: Put
--                        , _stepAuto :: !(a -> m (Output m a b))
--                        } deriving ( Typeable
--                                   , Generic
--                                   )

-- | Special case of 'Auto' where the underlying 'Monad' is 'Identity'.
type Auto'   = Auto Identity

-- | Special case of 'Output' where the underlying 'Monad' of 'outAuto' is
-- 'Identity'.
type Output' = Output Identity

-- | Re-structure 'Auto' internals to use the 'Arb' ("arbitrary")
-- constructors, as recursion-based mealy machines.  Almost always a bad
-- idea in every conceivable situation.  Why is it even here?
toArb :: Monad m => Auto m a b -> Auto m a b
toArb a = a_
  where
    a_ = case a of
           AutoFunc f  -> AutoArb  (pure a_)
                                   (return ())
                                 $ \x -> Output (f x) a_
           AutoFuncM f -> AutoArbM (pure a_)
                                   (return ())
                                 $ \x -> liftM (`Output` a_) (f x)
           AutoState gp@(g,p) f s  ->
                          let a__ s' = AutoArb (toArb . AutoState gp f <$> g)
                                               (p s')
                                             $ \x -> let (y, s'') = f x s'
                                                     in  Output y (a__ s'')
                          in  a__ s
           AutoStateM gp@(g,p) f s ->
                          let a__ s' = AutoArbM (toArb . AutoStateM gp f <$> g)
                                                (p s)
                                              $ \x -> do
                                                  (y, s'') <- f x s'
                                                  return (Output y (a__ s''))
                          in  a__ s
           _                       -> a


-- | Returns a string representation of the internal constructor of the
-- 'Auto'.  Useful for debugging the result of compositions and functions
-- and seeing how they affect the internal structure of the 'Auto'.
autoConstr :: Auto m a b -> String
autoConstr (AutoFunc {})   = "AutoFunc"
autoConstr (AutoFuncM {})  = "AutoFuncM"
autoConstr (AutoState {})  = "AutoState"
autoConstr (AutoStateM {}) = "AutoStateM"
autoConstr (AutoArb {})    = "AutoArb"
autoConstr (AutoArbM {})   = "AutoArbM"

-- | Swaps out the underlying 'Monad' of an 'Auto' using the given monad
-- morphism "transforming function".
--
-- Should be free for non-monadic functions.
hoistA :: (Monad m, Monad m')
       => (forall c. m c -> m' c)
       -> Auto m a b -> Auto m' a b
hoistA _ (AutoFunc f)        = AutoFunc f
hoistA g (AutoFuncM f)       = AutoFuncM (g . f)
hoistA _ (AutoState gp f s)  = AutoState gp f s
hoistA g (AutoStateM gp f s) = AutoStateM gp (\x s' -> g (f x s')) s
hoistA g (AutoArb gt pt f)   = AutoArb (fmap (hoistA g) gt)
                                       pt 
                                       $ \x -> let Output y a' = f x
                                               in  Output y (hoistA g a')
hoistA g (AutoArbM gt pt f)  = AutoArbM (fmap (hoistA g) gt)
                                        pt
                                        $ \x -> g $ do
                                            Output y a' <- f x
                                            return (Output y (hoistA g a'))
                                        
-- | Generalizes an 'Auto'' to any 'Auto' m a b', using 'hoist'.
--
-- Should be free for non-monadic functions.
generalizeA :: Monad m => Auto' a b -> Auto m a b
generalizeA = hoistA (return . runIdentity)

-- | Force the serializing components of an 'Auto'.
forceSerial :: Auto m a b -> Auto m a b
forceSerial a = case a of
                  AutoArb _ l s  -> l `seq` s `seq` a
                  AutoArbM _ l s -> l `seq` s `seq` a
                  _              -> a

-- $serializing
--
-- The 'Auto' type offers an interface in which you can serialize
-- ("freeze") and "resume" an Auto, in 'ByteString' (binary) form.
--
-- You can "freeze" any 'Auto' into a 'ByteString' using 'encodeAuto' (or,
-- if you want the raw 'Put' (from "Data.Serialize") for some reason,
-- there's 'saveAuto'.
--
-- You can "resume" any 'Auto' from a 'ByteString' using 'decodeAuto' (or,
-- if you want the raw 'Get' for some reason, there's 'loadAuto').
--
-- Note 'decodeAuto' and 'loadAuto' "resume" a /given 'Auto'/.  That is, if
-- you call 'decodeAuto' on a "fresh 'Auto'", it'll decode a 'ByteString'
-- into /that 'Auto', but "resumed"/.  That is, it'll "fast forward" that
-- 'Auto' into the state it was when it was saved.
--
-- For example, let's say I have @a = 'mkAccum' (+) 0@, the 'Auto' that
-- returns the sum of everything it has received so far.  If I feed it
-- 3 and 10, it'll have its internal accumulator as 13, keeping track of
-- all the numbers it has seen so far.
--
-- >>> let a             = mkAccum (+) 0
-- >>> let Output _ a'   = stepAuto' a  3
-- >>> let Output _ a''  = stepAuto' a' 10
--
-- I can then use 'encodeAuto' to "freeze"/"save" the 'Auto' into the
-- 'ByteString' @bs@:
--
-- >>> let bs            = encodeAuto a''
--
-- To "resume" / "load" it, I can use 'decodeAuto' to "resume" the
-- /original/ @a@.  Remember, 'a' was our original 'Auto', the summer
-- 'Auto' with a starting accumulator of 0.  We use 'decodeAuto' to
-- "resume" it, with and resume it with its internal accumulator at 13.
--
-- >>> let Right resumed = decodeAuto a bs
-- >>> let Output y _    = stepAuto' resumed 0
-- 13
--
-- Note that all of these would have had the same result:
--
-- >>> let Right resumed = decodeAuto a'  bs
-- >>> let Right resumed = decodeAuto a'' bs
-- >>> let Right resumed = decodeAuto (mkAccum (+) 0) bs
--
-- I mean, after all, if 'decodeAuto' "fast forwards" an 'Auto' to the
-- state it was at when it was frozen...then all of these should really be
-- resumed to the same point, right?
--
-- One way you can think about it is that 'loadAuto' / 'decodeAuto' takes
-- an 'Auto' and creates a "blueprint" from that 'Auto', on how to "load
-- it"; the blueprint contains what the form of the internal state is, and
-- their offets in the 'ByteString'.  So in the above, 'a', 'a'', 'a''',
-- and 'mkAccum (+) 0' all have the same "blueprint" --- their internal
-- states are of the same structure.
--
-- Some specific 'Auto's (indicated by a naming convention) might choose to
-- have internal state, yet ignore it when saving/loading.  So, saving it
-- actaully saves no state, and "resuming" it really doesn't do anything.
-- That is, @'decodeAuto' a_ bs = Right a_@.  There isn't a real way to
-- identify from the type of the 'Auto' if it will properly save/resume or
-- not, so you have to keep track of this yourself.  In all of the 'Auto'
-- "included" in this library, any 'Auto' whose name /does not/ end in @_@
-- /will serialize and resume/.  An 'Auto' whose name ends in @_@ is taken
-- by naming convention to be a non-resuming 'Auto'.
--
-- In your own compositions, if you are sure to always use resuming
-- 'Auto's, your composition will also be properly resuming...so you don't
-- have to worry about this!  You shouldn't really ever be "surprised",
-- because you'll always explicitly chose the resuming version for 'Auto's
-- you want to resume, and the non-resuming version for those you don't.
--
-- TODO: replace "decode" with "resume".

-- | Encode an 'Auto' and its internal state into a 'ByteString'.
encodeAuto :: Auto m a b -> ByteString
encodeAuto = runPut . saveAuto
{-# INLINE encodeAuto #-}

-- | "Resume" an 'Auto' from its 'ByteString' serialization, giving
-- a 'Left' if the deserialization is not possible.
decodeAuto :: Auto m a b -> ByteString -> Either String (Auto m a b)
decodeAuto = runGet . loadAuto
{-# INLINE decodeAuto #-}

-- | Returns a 'Get' from an 'Auto' ---  instructions (from
-- "Data.Serialize") on taking a ByteString and "restoring" the originally
-- saved 'Auto', in the originally saved state.
loadAuto :: Auto m a b -> Get (Auto m a b)
loadAuto a = case a of
               AutoState gp f _  -> AutoState  gp f <$> fst gp
               AutoStateM gp f _ -> AutoStateM gp f <$> fst gp
               AutoArb g _ _     -> g
               AutoArbM g _ _    -> g
               _                 -> return a
-- loadAuto = return
{-# INLINE loadAuto #-}

-- | Returns a 'Put' --- instructions (from "Data.Serialize") on how to
-- "freeze" the 'Auto', with its internal state, and save it to a binary
-- encoding.  It can later be reloaded and "resumed" by
-- 'loadAuto'/'decodeAuto'.
saveAuto :: Auto m a b -> Put
saveAuto a = case a of
               AutoState (_, p) _ s  -> p s
               AutoStateM (_, p) _ s -> p s
               AutoArb _ p _         -> p
               AutoArbM _ p _        -> p
               _                     -> return ()
-- saveAuto _ = return ()
{-# INLINE saveAuto #-}


-- | "Runs" the 'Auto' through one step.
--
-- Remember that at every step for an @'Auto' m a b@, you provide an @a@
-- input and receive a @b@ output with an "updated"/"next" 'Auto'.
--
-- >>> let a = mkAccum (+) 0 :: Auto Identity Int Int
--             -- an Auto that sums all of its input.
-- >>> let Identity (Output y a') = stepAuto a 3
-- >>> y      -- the result
-- 3 :: Int
-- >>> :t a'   -- the updated 'Auto'
-- a' :: Auto Identity Int Int
--
-- ('Identity', from "Data.Functor.Identity", is the "dumb Functor": @data
-- 'Identity' a = 'Identity' a@)
--
-- If you think of an @'Auto' m a b@ as a "stateful function" of type @a ->
-- m b@, then 'stepAuto' lets you "run" it.
stepAuto :: Monad m
         => Auto m a b        -- ^ the 'Auto' to step
         -> a                 -- ^ the input
         -> m (Output m a b)  -- ^ the output, and the updated 'Auto''.
stepAuto a x = case a of
                 AutoFunc f        ->
                     return (Output (f x) a)
                 AutoFuncM f       -> do
                     y <- f x
                     return (Output y a)
                 AutoState gp f s  ->
                     let (y, s') = f x s
                         a'      = AutoState gp f s'
                     in  return (Output y a')
                 AutoStateM gp f s -> do
                     (y, s') <- f x s
                     let a' = AutoStateM gp f s'
                     return (Output y a')
                 AutoArb _ _ f     -> return (f x)
                 AutoArbM _ _ f    -> f x
-- stepAuto a x = case a of
--                  AutoFunc f     -> let y = f x in y `seq` return (Output y a)
--                  AutoFuncM f    -> do
--                      y <- f x
--                      y `seq` return (Output y a)
--                  AutoState gp f s  -> let (y, s') = f x s
--                                           a'      = AutoState gp f s'
--                                       in  y `seq` return (Output y a')
--                  AutoStateM gp f s -> do
--                      (y, s') <- f x s
--                      let a' = AutoStateM gp f s'
--                      y `seq` return (Output y a')
--                  AutoArb _ _ f   -> let o@(Output y _) = f x in y `seq` return o
--                  AutoArbM _ _ f  -> do
--                      o@(Output y _) <- f x
--                      y `seq` return o
{-# INLINE stepAuto #-}

-- | 'stepAuto', but for an 'Auto'' --- the underlying 'Monad' is
-- 'Identity'.  Returns the output stripped of 'Identity'.
--
-- If you think of an @'Auto'' a b@ as a "stateful function" of type
-- @a -> b@, then 'stepAuto'' lets you "run" it.
stepAuto' :: Auto' a b        -- ^ the 'Auto'' to step
          -> a                -- ^ the input
          -> Output' a b      -- ^ the output, and the updated 'Auto''
stepAuto' a = runIdentity . stepAuto a
{-# INLINE stepAuto' #-}

evalAuto :: Monad m
         => Auto m a b
         -> a
         -> m b
evalAuto a = liftM outRes . stepAuto a

evalAuto' :: Auto' a b
          -> a
          -> b
evalAuto' a = outRes . stepAuto' a

execAuto :: Monad m
         => Auto m a b
         -> a
         -> m (Auto m a b)
execAuto a = liftM outAuto . stepAuto a

execAuto' :: Auto' a b
          -> a
          -> Auto' a b
execAuto' a = outAuto . stepAuto' a


-- | A special 'Auto' that acts like the 'id' 'Auto', but forces results as
-- they come through to be fully evaluated, when composed with other
-- 'Auto's.
forcer :: NFData a => Auto m a a
forcer = mkAuto_ $ \x -> x `deepseq` Output x forcer
{-# INLINE forcer #-}

-- | A special 'Auto' that acts like the 'id' 'Auto', but forces results as
-- they come through to be evaluated to Weak Head Normal Form, with 'seq',
-- when composed with other 'Auto's.
seqer :: Auto m a a
seqer = mkAuto_ $ \x -> x `seq` Output x seqer
{-# INLINE seqer #-}

-- compMAuto :: (Monad m, Monad m') => Auto m b (m' c) -> Auto m a (m' b) -> Auto m a (m' c)
-- compMAuto g f = AutoArbM undefined
--                          undefined
--                          $ \x -> do
--                              Output y f' <- stepAuto f x
--                              undefined
                                

-- doesn't work like you'd think lol.
-- serialForcer :: Monad m => Auto m a a
-- serialForcer = a
--   where
--     a = mkAuto_ $ \x -> let outp = Output x a
--                         in  forceSerial a `seq` outp

-- | Construct an 'Auto' by explicity giving its serialization,
-- deserialization, and the (pure) function from @a@ to @b@ and the "next
-- 'Auto'".
--
-- Ideally, you wouldn't have to use this unless you are making your own
-- framework.  Try your best to make what you want by assembling
-- primtives together.
mkAuto :: Get (Auto m a b)      -- ^ resuming/loading 'Get'
       -> Put                   -- ^ saving 'Put'
       -> (a -> Output m a b)   -- ^ step function
       -> Auto m a b
mkAuto = AutoArb
{-# INLINE mkAuto #-}

-- | Construct an 'Auto' by explicitly giving its serializiation,
-- deserialization, and the (monadic) function from @a@ to @b@ and the
-- "next 'Auto'".
--
-- Ideally, you wouldn't have to use this unless you are making your own
-- framework.  Try your best to make what you want by assembling
-- primtives together.
mkAutoM :: Get (Auto m a b)         -- ^ resuming/loading 'Get'
        -> Put                      -- ^ saving 'Put'
        -> (a -> m (Output m a b))  -- ^ (monadic) step function
        -> Auto m a b
mkAutoM = AutoArbM
{-# INLINE mkAutoM #-}

-- | Like 'mkAuto', but without any way of meaningful serializing or
-- deserializing.
--
-- Be careful!  This 'Auto' can still carry arbitrary internal state, but
-- it cannot be meaningfully serialized or re-loaded/resumed.  You can
-- still pretend to do so using
-- 'loadAuto'/'saveAuto'/'encodeAuto'/'decodeAuto' (and the type system
-- won't stop you), but when you try to "resume"/decode it, its state will
-- be lost.
mkAuto_ :: (a -> Output m a b)      -- ^ step function
        -> Auto m a b
mkAuto_ f = mkAuto (pure (mkAuto_ f)) (return ()) f
{-# INLINE mkAuto_ #-}

-- | Like 'mkAutoM', but without any way of meaningful serializing or
-- deserializing.
--
-- Be careful!  This 'Auto' can still carry arbitrary internal state, but
-- it cannot be meaningfully serialized or re-loaded/resumed.  You can
-- still pretend to do so using
-- 'loadAuto'/'saveAuto'/'encodeAuto'/'decodeAuto' (and the type system
-- won't stop you), but when you try to "resume"/decode it, its state will
-- be reset.
mkAutoM_ :: (a -> m (Output m a b))   -- ^ (monadic) step function
         -> Auto m a b
mkAutoM_ f = mkAutoM (pure (mkAutoM_ f)) (return ()) f
{-# INLINE mkAutoM_ #-}

-- | Construct the 'Auto' that always yields the given value, ignoring its
-- input.
--
-- Provided for API constency, but you should really be using 'pure' from
-- the 'Applicative' instance, from "Control.Applicative", which does the
-- same thing.
mkConst :: b            -- ^ constant value to be outputted
        -> Auto m a b
mkConst = AutoFunc . const
{-# INLINE mkConst #-}

-- | Construct the 'Auto' that always "executes" the given monadic value at
-- every step, yielding the result and ignoring its input.
--
-- Provided for API consistency, but you shold really be using 'effect'
-- from "Control.Auto.Effects", which does the same thing.
mkConstM :: m b           -- ^ monadic action to be executed at every step
         -> Auto m a b
mkConstM = AutoFuncM . const
{-# INLINE mkConstM #-}

-- | Construct a stateless 'Auto' that simply applies the given (pure)
-- function to every input, yielding the output.
--
-- This is rarely needed; you should be using 'arr' from the 'Arrow'
-- instance, from "Control.Arrow".
mkFunc :: (a -> b)        -- ^ pure function
       -> Auto m a b
mkFunc = AutoFunc
{-# INLINE mkFunc #-}

-- | Construct a statelss 'Auto' that simply applies and executes the givne
-- (monadic) function to every input, yielding the output.
--
-- It's recommended that you use 'arrM' from "Control.Auto.Effects".  This
-- is only really provided for consistency.
mkFuncM :: (a -> m b)     -- ^ "monadic" function
        -> Auto m a b
mkFuncM = AutoFuncM
{-# INLINE mkFuncM #-}

-- | Construct an 'Auto' from a state transformer: an @a -> s -> (b, s)@
-- gives you an @'Auto' m a b@, for any 'Monad' @m@.  At every step, it
-- takes in the @a@ input, runs the function with the stored internal
-- state, returns the @b@ result, and now contains the new resulting state.
-- You have to intialize it with an initial state, of course.
--
-- Try not to use this if it's ever avoidable, unless you're a framework
-- developer or something.  Try make something by combining/composing the
-- various 'Auto' combinators.
--
-- This version is a wrapper around 'mkAuto', that keeps track of the
-- serialization and re-loading of the internal state for you, so you don't
-- have to deal with it explicitly.
--
-- If your state @s@ does not have a 'Serialize' instance, then you should
-- either write a meaningful one, provide the serialization methods
-- manually with 'mkState'', or throw away serializability and use
-- 'mkState_'.
mkState :: Serialize s
        => (a -> s -> (b, s))       -- ^ state transformer
        -> s                        -- ^ intial state
        -> Auto m a b
mkState = AutoState (get, put)
{-# INLINE mkState #-}

-- | Construct an 'Auto' from a "monadic" state transformer: @a -> s ->
-- m (b, s)@ gives you an @'Auto' m a b@.  At every step, it takes in the
-- @a@ input, runs the function with the stored internal state and
-- "executes" the @m (b, s)@ to get the @b@ output, and stores the @s@ as
-- the new, updated state.  Must be initialized with an initial state.
--
-- Try not to use this if it's ever avoidable, unless you're a framework
-- developer or something.  Try make something by combining/composing the
-- various 'Auto' combinators.
--
-- This version is a wrapper around 'mkAuto', that keeps track of the
-- serialization and re-loading of the internal state for you, so you don't
-- have to deal with it explicitly.
--
-- If your state @s@ does not have a 'Serialize' instance, then you should
-- either write a meaningful one, provide the serialization methods
-- manually with 'mkStateM'', or throw away serializability and use
-- 'mkStateM_'.
mkStateM :: Serialize s
         => (a -> s -> m (b, s))      -- ^ (monadic) state transformer
         -> s                         -- ^ initial state
         -> Auto m a b
mkStateM = AutoStateM (get, put)
{-# INLINE mkStateM #-}

-- | A version of 'mkState', where the internal state doesn't have
-- a 'Serialize' instance, so you provide your own instructions for getting
-- and putting the state.
mkState' :: Get s                     -- ^ 'Get'; strategy for reading and deserializing the state
         -> (s -> Put)                -- ^ 'Put'; strategy for serializing given state
         -> (a -> s -> (b, s))        -- ^ state transformer
         -> s                         -- ^ intial state
         -> Auto m a b
mkState' = curry AutoState
{-# INLINE mkState' #-}

-- | A version of 'mkStateM', where the internal state doesn't have
-- a 'Serialize' instance, so you provide your own instructions for getting
-- and putting the state.
mkStateM' :: Get s                      -- ^ 'Get'; strategy for reading and deserializing the state
          -> (s -> Put)                 -- ^ 'Put'; strategy for serializing given state
          -> (a -> s -> m (b, s))       -- ^ (monadic) state transformer
          -> s                          -- ^ initial state
          -> Auto m a b
mkStateM' = curry AutoStateM
{-# INLINE mkStateM' #-}

-- | A version of 'mkState', where the internal state isn't serialized.  It
-- can be "saved" and "loaded", but the state is lost in the process.
--
-- Useful if your state @s@ cannot have a meaningful 'Serialize' instance.
mkState_ :: (a -> s -> (b, s))    -- ^ state transformer
         -> s                     -- ^ initial state
         -> Auto m a b
mkState_ f s0 = AutoState (return s0, \_ -> return ()) f s0
{-# INLINE mkState_ #-}

-- | A version of 'mkStateM', where the internal state isn't serialized.
-- It can be "saved" and "loaded", but the state is lost in the process.
--
-- Useful if your state @s@ cannot have a meaningful 'Serialize' instance.
mkStateM_ :: (a -> s -> m (b, s))   -- ^ (monadic) state transformer
          -> s                      -- ^ initial state
          -> Auto m a b
mkStateM_ f s0 = AutoStateM (return s0, \_ -> return ()) f s0
{-# INLINE mkStateM_ #-}

-- | Construct an 'Auto' from a "folding" function: @b -> a -> b@ yields an
-- @'Auto' m a b@.  Basically acts like a 'foldl' or a 'scanl'.  There is
-- an internal accumulator that is "updated" with an @a@ at every step.
-- Must be given an initial accumulator.
--
-- Example: an 'Auto' that sums up all of its input.
--
-- >>> let summer = mkAccum (+) 0
-- >>> let Output sum1 summer' = stepAuto summer 3
-- >>> sum1
-- 3
-- >>> let Output sum2 _       = stepAuto summer'' 10
-- >>> sum2
-- 13
--
-- If your accumulator @b@ does not have a 'Serialize' instance, then you
-- should either write a meaningful one, or throw away serializability and
-- use 'mkAccum_'.
mkAccum :: Serialize b
        => (b -> a -> b)      -- ^ accumulating function
        -> b                  -- ^ initial accumulator
        -> Auto m a b
mkAccum f = mkState (\x s -> let y = f s x in (y, y))
{-# INLINE mkAccum #-}

-- | Construct an 'Auto' from a "monadic" "folding" function: @b -> a ->
-- m b@ yields an @'Auto' m a b@.  Basically acts like a 'foldM' or 'scanM'
-- (if it existed).  here is an internal accumulator that is "updated" with
-- an input @a@ with the result of the executed @m b@ at every step.  Must
-- be given an initial accumulator.
--
-- If your accumulator @b@ does not have a 'Serialize' instance, then you
-- should either write a meaningful one, or throw away serializability and
-- use 'mkAccumM_'.
mkAccumM :: (Serialize b, Monad m)
         => (b -> a -> m b)       -- ^ (monadic) accumulating function
         -> b                     -- ^ initial accumulator
         -> Auto m a b
mkAccumM f = mkStateM (\x s -> liftM (join (,)) (f s x))
{-# INLINE mkAccumM #-}

-- | A version of 'mkAccum_, where the internal accumulator isn't
-- serialized. It can be "saved" and "loaded", but the state is lost in the
-- process.
--
-- Useful if your accumulator @b@ cannot have a meaningful 'Serialize'
-- instance.
mkAccum_ :: (b -> a -> b)   -- ^ accumulating function
         -> b               -- ^ intial accumulator
         -> Auto m a b
mkAccum_ f = mkState_ (\x s -> let y = f s x in (y, y))
{-# INLINE mkAccum_ #-}

-- | A version of 'mkAccumM_, where the internal accumulator isn't
-- serialized. It can be "saved" and "loaded", but the state is lost in the
-- process.
--
-- Useful if your accumulator @b@ cannot have a meaningful 'Serialize'
-- instance.
mkAccumM_ :: Monad m
          => (b -> a -> m b)    -- ^ (monadic) accumulating function
          -> b                  -- ^ initial accumulator
          -> Auto m a b
mkAccumM_ f = mkStateM_ (\x s -> liftM (join (,)) (f s x))
{-# INLINE mkAccumM_ #-}

-- | A "delayed" version of 'mkAccum', where the first output is actually
-- the initial state of the accumulator.  Useful in recursive bindings.
mkAccumD :: Serialize b
         => (b -> a -> b)      -- ^ accumulating function
         -> b                  -- ^ initial accumulator
         -> Auto m a b
mkAccumD f = mkState (\x s -> (s, f s x))
{-# INLINE mkAccumD #-}

-- | A "delayed" version of 'mkAccumM', where the first output is actually
-- the initial state of the accumulator.  Useful in recursive bindings.
mkAccumMD :: (Serialize b, Monad m)
          => (b -> a -> m b)       -- ^ (monadic) accumulating function
          -> b                     -- ^ initial accumulator
          -> Auto m a b
mkAccumMD f = mkStateM (\x s -> liftM (s,) (f s x))
{-# INLINE mkAccumMD #-}

-- | The non-resuming/non-serializing version of 'mkAccumD'.
mkAccumD_ :: (b -> a -> b)   -- ^ accumulating function
          -> b               -- ^ intial accumulator
          -> Auto m a b
mkAccumD_ f = mkState_ (\x s -> (s, f s x))
{-# INLINE mkAccumD_ #-}

-- | The non-resuming/non-serializing version of 'mkAccumMD'.
mkAccumMD_ :: Monad m
           => (b -> a -> m b)    -- ^ (monadic) accumulating function
           -> b                  -- ^ initial accumulator
           -> Auto m a b
mkAccumMD_ f = mkStateM_ (\x s -> liftM (s,) (f s x))
{-# INLINE mkAccumMD_ #-}


instance Monad m => Functor (Auto m a) where
    fmap = rmap
    {-# INLINE fmap #-}

instance Monad m => Applicative (Auto m a) where
    pure      = mkConst
    {-# INLINE pure #-}
    af <*> ax = mkAutoM ((<*>) <$> loadAuto af <*> loadAuto ax)
                        (saveAuto af *> saveAuto ax)
                        $ \x -> liftM2 (<*>) (stepAuto af x) (stepAuto ax x)
    {-# INLINE (<*>) #-}

-- Should this even be here?  It might be kind of dangerous/unexpected.
instance (Monad m, Alternative m) => Alternative (Auto m a) where
    empty     = mkConstM empty
    a1 <|> a2 = mkAutoM ((<|>) <$> loadAuto a1 <*> loadAuto a2)
                        (saveAuto a1 *> saveAuto a2)
                        $ \x -> let res1  = onOutAuto (<|> a2) `liftM` stepAuto a1 x
                                    res2  = onOutAuto (a1 <|>) `liftM` stepAuto a2 x
                                in  res1 <|> res2


instance Monad m => Category (Auto m) where
    id      = mkFunc id
    ag . af = case (ag, af) of
                (AutoFunc g, AutoFunc f)          ->
                    AutoFunc   (g . f)
                (AutoFunc g, AutoFuncM f)         ->
                    AutoFuncM  (return . g <=< f)
                (AutoFunc g, AutoState gpf f s)   ->
                    AutoState gpf (\x s' -> first g (f x s')) s
                (AutoFunc g, AutoStateM gpf f s)  ->
                    AutoStateM gpf (\x s' -> liftM (first g) (f x s')) s
                (AutoFunc g, AutoArb l s f)       ->
                    AutoArb (fmap (ag .) l) s $ \x -> fmap g (f x)
                (AutoFunc g, AutoArbM l s f)      ->
                    AutoArbM (fmap (ag .) l) s $ \x -> liftM (fmap g) (f x)
                (AutoFuncM g, AutoFunc f)         ->
                    AutoFuncM (g <=< return . f)
                (AutoFuncM g, AutoFuncM f)        ->
                    AutoFuncM (g <=< f)
                (AutoFuncM g, AutoState gpf f s)  ->
                    AutoStateM gpf (\x s' -> firstM g (f x s')) s
                (AutoFuncM g, AutoStateM gpf f s) ->
                    AutoStateM gpf (\x s' -> firstM g =<< f x s') s
                (AutoFuncM g, AutoArb l s f)      ->
                    AutoArbM (fmap (ag .) l)
                             s
                           $ \x -> do
                               let Output y af' = f x
                               y' <- g y
                               return (Output y' (ag . af'))
                (AutoFuncM g, AutoArbM l s f)     ->
                    AutoArbM (fmap (ag .) l)
                             s
                           $ \x -> do
                               Output y af' <- f x
                               y' <- g y
                               return (Output y' (ag . af'))
                (AutoState gpg g sg, AutoFunc f)  ->
                    AutoState gpg (g . f) sg
                (AutoState gpg g sg, AutoFuncM f) ->
                    AutoStateM gpg (\x sg' -> liftM (`g` sg') (f x)) sg
                (AutoState gpg g sg, AutoState gpf f sf) ->
                    AutoState (mergeStSt gpg gpf)
                              (\x (sg', sf') -> let (y, sf'') = f x sf'
                                                    (z, sg'') = g y sg'
                                                in  (z, (sg'', sf'')) )
                              (sg, sf)
                (AutoState gpg g sg, AutoStateM gpf f sf) ->
                    AutoStateM (mergeStSt gpg gpf)
                               (\x (sg', sf') -> do
                                    (y, sf'') <- f x sf'
                                    let (z, sg'') = g y sg'
                                    return (z, (sg'', sf'')) )
                               (sg, sf)
                (AutoState gpg@(gg,pg) g sg, AutoArb l s f) ->
                    AutoArb (liftA2 (\sg' af' -> AutoState gpg g sg' . af') gg l)
                            (pg sg *> s)
                            $ \x -> let Output y af' = f x
                                        (z, sg')     = g y sg
                                        ag'          = AutoState gpg g sg'
                                    in  Output z (ag' . af')
                (AutoState gpg@(gg,pg) g sg, AutoArbM l s f) ->
                    AutoArbM (liftA2 (\sg' af' -> AutoState gpg g sg' . af') gg l)
                             (pg sg *> s)
                             $ \x -> do
                                 Output y af' <- f x
                                 let (z, sg') = g y sg
                                     ag'      = AutoState gpg g sg'
                                 return (Output z (ag' . af'))
                (AutoStateM gpg g sg, AutoFunc f)       ->
                    AutoStateM gpg (g <=< return . f) sg
                (AutoStateM gpg g sg, AutoFuncM f)      ->
                    AutoStateM gpg (\x sg' -> flip g sg' =<< f x) sg
                (AutoStateM gpg g sg, AutoState gpf f sf) ->
                    AutoStateM (mergeStSt gpg gpf)
                               (\x (sg', sf') -> do
                                  let (y, sf'') = f x sf'
                                  (z, sg'') <- g y sg'
                                  return (z, (sg'', sf'')) )
                               (sg, sf)
                (AutoStateM gpg g sg, AutoStateM gpf f sf) ->
                    AutoStateM (mergeStSt gpg gpf)
                               (\x (sg', sf') -> do
                                  (y, sf'') <- f x sf'
                                  (z, sg'') <- g y sg'
                                  return (z, (sg'', sf'')) )
                               (sg, sf)
                (AutoStateM gpg@(gg,pg) g sg, AutoArb l s f) ->
                    AutoArbM (liftA2 (\sg' af' -> AutoStateM gpg g sg' . af') gg l)
                             (pg sg *> s)
                             $ \x -> do
                                 let Output y af' = f x
                                 (z, sg') <- g y sg
                                 let ag' = AutoStateM gpg g sg'
                                 return (Output z (ag' . af'))
                (AutoStateM gpg@(gg,pg) g sg, AutoArbM l s f) ->
                    AutoArbM (liftA2 (\sg' af' -> AutoStateM gpg g sg' . af') gg l)
                             (pg sg *> s)
                             $ \x -> do
                                 Output y af' <- f x
                                 (z, sg') <- g y sg
                                 let ag' = AutoStateM gpg g sg'
                                 return (Output z (ag' . af'))
                (AutoArb l s g, AutoFunc f)  ->
                    AutoArb (fmap (. af) l) s (onOutAuto (. af) . g . f)
                (AutoArb l s g, AutoFuncM f) ->
                    AutoArbM (fmap (. af) l) s (return . onOutAuto (. af) . g <=< f)
                (AutoArb l s g, AutoState gpf@(gf,pf) f sf) ->
                    AutoArb (liftA2 (\ag' sf' -> ag' . AutoState gpf f sf') l gf)
                            (s *> pf sf)
                            $ \x -> let (y, sf')     = f x sf
                                        af'          = AutoState gpf f sf'
                                        Output z ag' = g y
                                    in  Output z (ag' . af')
                (AutoArb l s g, AutoStateM gpf@(gf,pf) f sf) ->
                    AutoArbM (liftA2 (\ag' sf' -> ag' . AutoStateM gpf f sf') l gf)
                             (s *> pf sf)
                             $ \x -> do
                                 (y, sf') <- f x sf
                                 let af'          = AutoStateM gpf f sf'
                                     Output z ag' = g y
                                 return (Output z (ag' . af'))
                (AutoArb lg sg g, AutoArb lf sf f) ->
                    AutoArb (liftA2 (.) lg lf)
                            (sg *> sf)
                            $ \x -> let Output y af' = f x
                                        Output z ag' = g y
                                    in  Output z (ag' . af')
                (AutoArb lg sg g, AutoArbM lf sf f) ->
                    AutoArbM (liftA2 (.) lg lf)
                             (sg *> sf)
                             $ \x -> do
                                 Output y af' <- f x
                                 let Output z ag' = g y
                                 return (Output z (ag' . af'))
                (AutoArbM l s g, AutoFunc f)  ->
                    AutoArbM (fmap (. af) l)
                             s
                             (liftM (onOutAuto (. af)) . g . f)
                (AutoArbM l s g, AutoFuncM f) ->
                    AutoArbM (fmap (. af) l)
                             s
                             (liftM (onOutAuto (. af)) . g <=< f)
                (AutoArbM l s g, AutoState gpf@(gf,pf) f sf) ->
                    AutoArbM (liftA2 (\ag' sf' -> ag' . AutoState gpf f sf') l gf)
                             (s *> pf sf)
                             $ \x -> do
                                 let (y, sf') = f x sf
                                     af'      = AutoState gpf f sf'
                                 Output z ag' <- g y
                                 return (Output z (ag' . af'))
                (AutoArbM l s g, AutoStateM gpf@(gf,pf) f sf) ->
                    AutoArbM (liftA2 (\ag' sf' -> ag' . AutoStateM gpf f sf') l gf)
                             (s *> pf sf)
                             $ \x -> do
                                 (y, sf') <- f x sf
                                 let af' = AutoStateM gpf f sf'
                                 Output z ag' <- g y
                                 return (Output z (ag' . af'))
                (AutoArbM lg sg g, AutoArb lf sf f) ->
                    AutoArbM (liftA2 (.) lg lf)
                             (sg *> sf)
                             $ \x -> do
                                 let Output y af' = f x
                                 Output z ag' <- g y
                                 return (Output z (ag' . af'))
                (AutoArbM lg sg g, AutoArbM lf sf f) ->
                    AutoArbM (liftA2 (.) lg lf)
                             (sg *> sf)
                             $ \x -> do
                                 Output y af' <- f x
                                 Output z ag' <- g y
                                 return (Output z (ag' . af'))
      where
        mergeStSt (gg, pg) (gf, pf) = (liftA2 (,) gg gf, uncurry (*>) . (pg *** pf))
    {-# INLINE (.) #-}

instance Monad m => Profunctor (Auto m) where
    lmap f = a_
      where
        a_ a = case a of
                 AutoFunc fa         -> AutoFunc (fa . f)
                 AutoFuncM fa        -> AutoFuncM (fa . f)
                 AutoState gpg fa s  -> AutoState gpg (fa . f) s
                 AutoStateM gpg fa s -> AutoStateM gpg (fa . f) s
                 AutoArb l s fa      -> AutoArb (a_ <$> l)
                                                s
                                              $ \x -> let Output y a' = fa (f x)
                                                      in  Output y (a_ a')
                 AutoArbM l s fa     -> AutoArbM (a_ <$> l)
                                                 s
                                              $ \x -> do
                                                  Output y a' <- fa (f x)
                                                  return (Output y (a_ a'))
    {-# INLINE lmap #-}
    rmap g = a_
      where
        a_ a = case a of
                 AutoFunc fa         -> AutoFunc (g . fa)
                 AutoFuncM fa        -> AutoFuncM (liftM g . fa)
                 AutoState gpg fa s  -> AutoState gpg (\x -> first g . fa x) s
                 AutoStateM gpg fa s -> AutoStateM gpg (\x -> liftM (first g) . fa x) s
                 AutoArb l s fa      -> AutoArb (a_ <$> l)
                                                s
                                              $ \x -> let Output y a' = fa x
                                                      in  Output (g y) (a_ a')
                 AutoArbM l s fa     -> AutoArbM (a_ <$> l)
                                                 s
                                               $ \x -> do
                                                   Output y a' <- fa x
                                                   return (Output (g y) (a_ a'))
    {-# INLINE rmap #-}
    dimap f g = a_
      where
        a_ a = case a of
                 AutoFunc fa         -> AutoFunc (g . fa . f)
                 AutoFuncM fa        -> AutoFuncM (liftM g . fa . f)
                 AutoState gpg fa s  -> AutoState gpg (\x -> first g . fa (f x)) s
                 AutoStateM gpg fa s -> AutoStateM gpg (\x -> liftM (first g) . fa (f x)) s
                 AutoArb l s fa      -> AutoArb (a_ <$> l)
                                                s
                                              $ \x -> let Output y a' = fa (f x)
                                                      in  Output (g y) (a_ a')
                 AutoArbM l s fa     -> AutoArbM (a_ <$> l)
                                                 s
                                               $ \x -> do
                                                   Output y a' <- fa (f x)
                                                   return (Output (g y) (a_ a'))
    {-# INLINE dimap #-}

instance Monad m => Arrow (Auto m) where
    arr     = mkFunc
    first a = case a of
                AutoFunc f         -> AutoFunc (first f)
                AutoFuncM f        -> AutoFuncM (firstM f)
                AutoState gp fa s  -> AutoState gp (\(x, z) -> first (,z) . fa x) s
                AutoStateM gp fa s -> AutoStateM gp (\(x, z) -> liftM (first (,z)) . fa x) s
                AutoArb l s f      -> AutoArb (first <$> l)
                                              s
                                            $ \(x, z) -> let Output y a' = f x
                                                         in  Output (y, z) (first a')
                AutoArbM l s f     -> AutoArbM (first <$> l)
                                               s
                                             $ \(x, z) -> do
                                                 Output y a' <- f x
                                                 return (Output (y, z) (first a'))

instance Monad m => ArrowChoice (Auto m) where
    left a0 = a
      where
        a = case a0 of
              AutoFunc f        ->
                  AutoFunc (left f)
              AutoFuncM f       ->
                  AutoFuncM (\x -> case x of
                               Left y  -> liftM Left (f y)
                               Right y -> return (Right y))
              AutoState gp f s  ->
                  AutoState gp (\x s' -> case x of
                                  Left y  -> first Left (f y s')
                                  Right y -> (Right y, s')) s
              AutoStateM gp f s ->
                  AutoStateM gp (\x s' -> case x of
                                   Left y  -> liftM (first Left) (f y s')
                                   Right y -> return (Right y, s')) s
              AutoArb l s f     ->
                  AutoArb (left <$> l)
                          s
                        $ \x -> case x of
                                  Left y  -> onOutput Left left (f y)
                                  Right y -> Output (Right y) a
              AutoArbM l s f    ->
                  AutoArbM (left <$> l)
                           s
                         $ \x -> case x of
                                   Left y  -> liftM (onOutput Left left) (f y)
                                   Right y -> return (Output (Right y) a)
    {-# INLINE left #-}

instance MonadFix m => ArrowLoop (Auto m) where
    loop a = case a of
                AutoFunc f        -> AutoFunc (\x -> fst . fix $ \(_, d) -> f (x, d))
                AutoFuncM f       -> AutoFuncM (\x -> liftM fst . mfix $ \(_, d) -> f (x, d))
                AutoState gp f s  -> AutoState gp (\x s' -> first fst . fix $ \ ~((_, d), _) -> f (x, d) s') s
                AutoStateM gp f s -> AutoStateM gp (\x s' -> liftM (first fst) . mfix $ \ ~((_, d), _) -> f (x, d) s') s
                AutoArb l s f     -> AutoArb (loop <$> l)
                                             s
                                           $ \x -> onOutput fst loop
                                                 . fix
                                                 $ \ ~(Output (_, d) _) -> f (x, d)
                AutoArbM l s f    -> AutoArbM (loop <$> l)
                                              s
                                            $ \x -> liftM (onOutput fst loop)
                                                  . mfix
                                                  $ \ ~(Output (_, d) _) -> f (x, d)
    {-# INLINE loop #-}

-- Utility instances

instance (Monad m, Semigroup b) => Semigroup (Auto m a b) where
    (<>) = liftA2 (<>)

instance (Monad m, Monoid b) => Monoid (Auto m a b) where
    mempty  = pure mempty
    mappend = liftA2 mappend

instance (Monad m, Num b) => Num (Auto m a b) where
    (+)         = liftA2 (+)
    (*)         = liftA2 (*)
    (-)         = liftA2 (-)
    negate      = liftA negate
    abs         = liftA abs
    signum      = liftA signum
    fromInteger = pure . fromInteger

instance (Monad m, Fractional b) => Fractional (Auto m a b) where
    (/)          = liftA2 (/)
    recip        = liftA recip
    fromRational = pure . fromRational

instance (Monad m, Floating b) => Floating (Auto m a b) where
    pi      = pure pi
    exp     = liftA exp
    sqrt    = liftA sqrt
    log     = liftA log
    (**)    = liftA2 (**)
    logBase = liftA2 logBase
    sin     = liftA sin
    tan     = liftA tan
    cos     = liftA cos
    asin    = liftA asin
    atan    = liftA atan
    acos    = liftA acos
    sinh    = liftA sinh
    tanh    = liftA tanh
    cosh    = liftA cosh
    asinh   = liftA asinh
    atanh   = liftA atanh
    acosh   = liftA acosh

-- Semigroup, Monoid, Num, Fractional, and Floating instances for Output
-- because why not.

instance (Monad m, Semigroup b) => Semigroup (Output m a b) where
    (<>) = liftA2 (<>)

instance (Monad m, Monoid b) => Monoid (Output m a b) where
    mempty  = pure mempty
    mappend = liftA2 mappend

instance (Monad m, Num b) => Num (Output m a b) where
    (+)         = liftA2 (+)
    (*)         = liftA2 (*)
    (-)         = liftA2 (-)
    negate      = liftA negate
    abs         = liftA abs
    signum      = liftA signum
    fromInteger = pure . fromInteger

instance (Monad m, Fractional b) => Fractional (Output m a b) where
    (/)          = liftA2 (/)
    recip        = liftA recip
    fromRational = pure . fromRational

instance (Monad m, Floating b) => Floating (Output m a b) where
    pi      = pure pi
    exp     = liftA exp
    sqrt    = liftA sqrt
    log     = liftA log
    (**)    = liftA2 (**)
    logBase = liftA2 logBase
    sin     = liftA sin
    tan     = liftA tan
    cos     = liftA cos
    asin    = liftA asin
    atan    = liftA atan
    acos    = liftA acos
    sinh    = liftA sinh
    tanh    = liftA tanh
    cosh    = liftA cosh
    asinh   = liftA asinh
    atanh   = liftA atanh
    acosh   = liftA acosh

-- Utility function
firstM :: Monad m => (a -> m b) -> (a, c) -> m (b, c)
firstM f (x, y) = liftM (, y) (f x)
{-# INLINE firstM #-}
