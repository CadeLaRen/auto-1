module Control.Auto.Interval (
  -- * Static intervals
    off
  , toOn
  , fromInterval
  , fromIntervalWith
  , onFor
  , offFor
  -- , window
  -- * Filter intervals
  , when
  , unless
  -- * Choice
  , (<|?>)
  , (<|!>)
  , chooseInterval
  , choose
  -- * Blip-based intervals
  , after
  , before
  , between
  , hold
  , hold_
  , holdFor
  , holdFor_
  -- * Composing with intervals
  , during
  , bindI
  ) where

import Control.Applicative
import Control.Auto.Blip.Internal
import Control.Auto.Core
import Control.Category
import Control.Monad (join)
import Data.Foldable (asum)
import Data.Traversable (sequenceA)
import Data.Maybe
import Data.Serialize
import Prelude hiding             ((.), id)

infixr 3 <|?>
infixr 3 <|!>

-- | An 'Auto' that produces an interval that always "off" ('Nothing'),
-- never letting anything pass.
off :: Auto m a (Maybe b)
off = mkConst Nothing

-- | An 'Auto' that takes a value stream and turns it into an "always-on"
-- interval, with that value.  Lets every value pass through.
--
-- prop> toOn == arr Just
toOn :: Auto m a (Maybe a)
toOn = mkFunc Just

-- | An 'Auto' taking in an interval stream and transforming it into
-- a normal value stream, using the given default value whenever the
-- interval is off/blocking.
--
-- prop> fromInterval d = arr (fromMaybe d)
fromInterval :: a       -- ^ value to output for "off" periods
             -> Auto m (Maybe a) a
fromInterval d = mkFunc (fromMaybe d)

-- | An 'Auto' taking in an interval stream and transforming it into
-- a normal value stream, using the given default value whenever the
-- interval is off/blocking, and applying the given function to the input
-- when the interval is on/passing.  Analogous to 'maybe' from "Prelude"
-- and "Data.Maybe".
--
-- prop> fromIntervalWith d f = arr (maybe d f)
fromIntervalWith :: b
                 -> (a -> b)
                 -> Auto m (Maybe a) b
fromIntervalWith d f = mkFunc (maybe d f)

-- | An 'Auto' that behaves like 'toOn' (letting values pass, "on")
-- for the given number of steps, then otherwise is off (preventing all
-- values from passing) forevermore.
--
onFor :: Int      -- ^ amount of steps to stay "on" for
      -> Auto m a (Maybe a)
onFor = mkState f . max 0
  where
    f _ 0 = (Nothing, 0    )
    f x i = (Just x , i - 1)

-- | An 'Auto' that is off for the given number of steps, suppressing all
-- input values, then behaves like 'toOn' forevermore, passing through
-- values as "on" values.
offFor :: Int     -- ^ amount of steps to be "off" for.
       -> Auto m a (Maybe a)
offFor = mkState f . max 0
  where
    f x 0 = (Just x , 0    )
    f _ i = (Nothing, i - 1)

-- window :: Int -> Int -> Auto m a (Maybe a)
-- window b e = mkState f (Just 1)
--   where
--     f _ Nothing              = (Nothing, Nothing)
--     f x (Just i) | i > e     = (Nothing, Nothing)
--                  | i < b     = (Nothing, Just (i + 1))
--                  | otherwise = (Just x , Just (i + 1))

-- | An 'Auto' that allows values to pass whenever the input satisfies the
-- predicate...and is off otherwise.
--
-- >>> let a = when (\x -> x >= 2 && x <= 4) . count
-- >>> let Output res _ = stepAutoN' 6 a ()
-- >>> res
-- [Nothing, Just 2, Just 3, Just 4, Nothing, Nothing]
--
-- ('count' is the 'Auto' that ignores its input and outputs the current
-- step count at every step)
--
when :: (a -> Bool)   -- ^ interval predicate
     -> Auto m a (Maybe a)
when p = mkFunc f
  where
    f x | p x       = Just x
        | otherwise = Nothing

-- | Like 'when', but only allows values to pass whenever the input does
-- not satisfy the predicate.  Blocks whenever the predicate is true.
--
-- >>> let a = unless (\x -> x < 2 &&& x > 4) . count
-- >>> let Output res _ = stepAutoN' 6 a ()
-- >>> res
-- [Nothing, Just 2, Just 3, Just 4, Nothing, Nothing]
--
-- ('count' is the 'Auto' that ignores its input and outputs the current
-- step count at every step)
--
unless :: (a -> Bool)   -- ^ interval predicate
       -> Auto m a (Maybe a)
unless p = mkFunc f
  where
    f x | p x       = Nothing
        | otherwise = Just x

-- | Takes in a value stream and a 'Blip' stream.  Doesn't allow any values
-- in at first, until the 'Blip' stream emits.  Then, allows all values
-- through as "on" forevermore.
--
-- >>> let a = after . (count &&& inB 3)
-- >>> let Output res _ = stepAutoN' 5 a ()
-- >>> res
-- [Nothing, Nothing, Just 3, Just 4, Just 4]
--
-- 'count' is the 'Auto' that ignores its input and outputs the current
-- step count at every step, and @'inB' 3@ is the 'Auto' generating
-- a 'Blip' stream that emits at the third step.
--
after :: Auto m (a, Blip b) (Maybe a)
after = mkState f False
  where
    f (x, _     ) True  = (Just x , True )
    f (x, Blip _) False = (Just x , True )
    f _           False = (Nothing, False)

-- | Takes in a value stream and a 'Blip' stream.  Allows all values
-- through, as "on", until the 'Blip' stream emits...then doesn't let
-- anything pass after that.
--
-- >>> let a = before . (count &&& inB 3)
-- >>> let Output res _ = stepAutoN' 5 a ()
-- >>> res
-- [Just 1, Just 2, Nothing, Nothing, Nothing]
--
-- 'count' is the 'Auto' that ignores its input and outputs the current
-- step count at every step, and @'inB' 3@ is the 'Auto' generating
-- a 'Blip' stream that emits at the third step.
--
before :: Auto m (a, Blip b) (Maybe a)
before = mkState f False
  where
    f _           True  = (Nothing, True )
    f (_, Blip _) False = (Nothing, True )
    f (x, _     ) False = (Just x , False)

-- | Takes in a value stream and two 'Blip' streams.  Starts off as "off",
-- not letting anything pass.  When the first 'Blip' stream emits, it
-- toggles onto the "on" state and lets everything pass; when the second
-- 'Blip' stream emits, it toggles back onto the "off" state.
--
-- >>> let a = before . (count &&& (inB 3 &&& inB 5))
-- >>> let Output res _ = stepAutoN' 7 a ()
-- >>> res
-- [Nothing, Nothing, Just 3, Just 4, Nothing, Nothing, Nothing]
between :: Auto m (a, (Blip b, Blip c)) (Maybe a)
between = mkState f False
  where
    f (_, (_, Blip _)) _     = (Nothing, False)
    f (x, (Blip _, _)) _     = (Just x , True )
    f (x, _          ) True  = (Just x , True )
    f _                False = (Nothing, False)

-- | Takes in a 'Blip' stream and constantly outputs the last emitted
-- value.  Starts off as 'Nothing'.
--
-- >>> let a1 = hold . inB 3 . count
-- >>> let Output res1 _ = stepAutoN' 5 a1 ()
-- >>> res1
-- [Nothing, Nothing, Just 3, Just 3, Just 3]
--
-- You can make this behave as an @'Auto' m ('Blip' a) b@ (no possible
-- 'Nothing's) by providing a "default" value, to be used when the input
-- stream has not yet emitted, in one of two ways:
--
-- The first, using '(<|!>)':
--
-- >>> let a2 = (hold . inB 3 . count) <|!> pure 100
-- >>> let Output res2 _ = stepAutoN' 5 a2 ()
-- >>> res2
-- [100, 100, 3, 3, 3]
--
-- The second, using 'fromInterval':
--
-- >>> let a3 = fromInterval 100 . hold . inB 3 . count
-- >>> let Output res3 _ = stepAutoN' 5 a3 ()
-- >>> res3
-- [100, 100, 3, 3, 3]
--
hold :: Serialize a => Auto m (Blip a) (Maybe a)
hold = mkAccum f Nothing
  where
    f x = blip x Just

-- | The non-serializing/non-resuming version of 'hold'.
hold_ :: Auto m (Blip a) (Maybe a)
hold_ = mkAccum_ f Nothing
  where
    f x = blip x Just

-- | Like 'hold', but it only "holds" the last emitted value for the given
-- number of steps.
--
-- >>> let a = holdFor 2 . inB 3 . count
-- >>> let Output res _ = stepAutoN' 7 a ()
-- >>> res
-- [Nothing, Nothing, Just 3, Just 4, Nothing, Nothing, Nothing]
--
holdFor :: Serialize a
        => Int      -- ^ number of steps to hold the last emitted value for
        -> Auto m (Blip a) (Maybe a)
holdFor n = mkState (_holdForF n) (Nothing, max 0 n)

-- | The non-serializing/non-resuming version of 'holdFor'.
holdFor_ :: Int   -- ^ number of steps to hold the last emitted value for
         -> Auto m (Blip a) (Maybe a)
holdFor_ n = mkState_ (_holdForF n) (Nothing, max 0 n)

_holdForF :: Int -> Blip a -> (Maybe a, Int) -> (Maybe a, (Maybe a, Int))
_holdForF n = f   -- n should be >= 0
  where
    f x s = (y, (y, i))
      where
        (y, i) = case (x, s) of
                   (Blip b,  _    ) -> (Just b , n    )
                   (_     , (_, 0)) -> (Nothing, 0    )
                   (_     , (z, j)) -> (z      , j - 1)

-- | "Chooses" between two interval-producing 'Auto's; behaves like the
-- first 'Auto' if it is "on"; otherwise, behaves like the second.
--
-- >>> let a = (onFor 2 . pure "hello") <|?> (onFor 4 . pure "world")
-- >>> let Output res _ = stepAutoN' 5 a ()
-- >>> res
-- [Just "hello", Just "hello", Just "world", Just "world", Nothing]
--
-- You can drop the parentheses, because of precedence; the above could
-- have been written as:
--
-- >>> let a' = onFor 2 . pure "hello" <|?> onFor 4 . pure "world"
--
-- Warning: If your underlying monad produces effects, remember that /both/
-- 'Auto's are run at every step, along with any monadic effects,
-- regardless of whether they are "on" or "off".
--
-- Note that more often than not, '(<|!>)' is probably more useful.  This
-- is useful only in the case that you really, really want an interval at
-- the end of it all.
--
(<|?>) :: Monad m
       => Auto m a (Maybe b)    -- ^ choice 1
       -> Auto m a (Maybe b)    -- ^ choice 2
       -> Auto m a (Maybe b)
(<|?>) = liftA2 (<|>)

-- | "Chooses" between an interval-producing 'Auto' and an "normal" value,
-- "always on" 'Auto'.  Behaves like the "on" value of the first 'Auto' if
-- it is on; otherwise, behaves like the second.
--
-- >>> let a1 = (onFor 2 . pure "hello") <|!> pure "world"
-- >>> let Output res1 _ = stepAutoN' 5 a1 ()
-- >>> res1
-- ["hello", "hello", "world", "world", "world"]
--
-- This one is neat because it associates from the right, so it can be
-- "chained":
--
-- >>> let a2 = onFor 2 . pure "hello"
--         <|!> onFor 4 . pure "world"
--         <|!> pure "goodbye!"
-- >>> let Output res2 _ = stepAutoN' 6 a2 ()
-- >>> res2
-- ["hello", "hello", "world", "world", "goodbye!", "goodbye!"]
--
-- @a <|!> b <|!> c@ associates as @a <|!> (b <|!> c)@
--
-- So using this, you can "chain" a bunch of choices between intervals, and
-- then at the right-most, "final" one, provide the default behavior.
--
-- Warning: If your underlying monad produces effects, remember that /both/
-- 'Auto's are run at every step, along with any monadic effects,
-- regardless of whether they are "on" or "off".
(<|!>) :: Monad m
       => Auto m a (Maybe b)      -- ^ interval 'Auto'
       -> Auto m a b              -- ^ "normal" 'Auto'
       -> Auto m a b
(<|!>) = liftA2 (flip fromMaybe)

-- | Run all 'Auto's from the same input, and return the behavior of the
-- first one that is not 'Nothing'.  If all are 'Nothing', output
-- 'Nothing'.
--
-- prop> chooseInterval == foldr (<|?>) off
chooseInterval :: Monad m
               => [Auto m a (Maybe b)]    -- ^ the 'Auto's to run and
                                          --   choose from
               -> Auto m a (Maybe b)
chooseInterval = fmap asum . sequenceA

-- | Run all 'Auto's from the same input, and return the behavior of the
-- first one that is not 'Nothing'; if all are 'Nothing', return the
-- behavior of the "default case".
--
-- prop> choose = foldr (<|!>)
choose :: Monad m
       => Auto m a b            -- ^ the 'Auto' to behave like if all
                                --   others are 'Nothing'
       -> [Auto m a (Maybe b)]  -- ^ 'Auto's to run and choose from
       -> Auto m a b
choose = foldr (<|!>)


-- | "Lifts" an @'Auto' m a b@ (transforming @a@s into @b@s) into an
-- @'Auto' m ('Maybe' a) ('Maybe' b)@, transforming /intervals/ of @a@s
-- into /intervals/ of @b@.
--
-- It does this by "running" the given 'Auto' whenever it receives a 'Just'
-- value, and skipping/pausing it whenever it receives a 'Nothing' value.
--
-- >>> let a1 = during (sumFrom 0) . onFor 2 . pure 1
-- >>> let Output res1 _ = stepAutoN 5 a1 ()
-- >>> res1
-- [Just 1, Just 2, Nothing, Nothing, Nothing]
-- >>> let a2 = during (sumFrom 0) . offFor 2 . pure 1
-- >>> let Output res2 _ = stepAutoN 5 a2 ()
-- >>> res2
-- [Nothing, Nothing, Just 1, Just 2, Just 3]
--
-- (Remember that @'pure' x@ is the 'Auto' that ignores its input and
-- constantly just pumps out @x@ at every step)
--
-- Note the difference between putting the 'sumFrom' "after" the
-- 'offFor' in the chain with 'during' (like the previous example)
-- and putting the 'sumFrom' "before":
--
-- >>> let a3 = offFor 2 . sumFrom 0 . pure 1
-- >>> let Output res3 _ = stepAutoN 5 a3 ()
-- >>> res3
-- [Nothing, Nothing, Just 3, Just 4, Just 5]
--
-- In the first case (with @a2@), the output of @'pure' 1@ was suppressed
-- by 'offFor', and @'during' ('sumFrom' 0)@ was only summing on the times
-- that the 1's were "allowed through"...so it only "starts counting" on
-- the third step.
--
-- In the second case (with @a3@), the output of the @'pure' 1@ is never
-- suppressed, and went straight into the @'sumFrom' 0@.  'sumFrom' is
-- always summing, the entire time.  The final output of that @'sumFrom' 0@
-- is suppressed at the end with @'offFor' 2@.
--
during :: Monad m => Auto m a b -> Auto m (Maybe a) (Maybe b)
during a = a_
  where
    a_ = mkAutoM (during <$> loadAuto a)
                 (saveAuto a)
                 $ \x -> case x of
                           Just x' -> do
                             Output y a' <- stepAuto a x'
                             return (Output (Just y) (during a'))
                           Nothing ->
                             return (Output Nothing  a_         )

-- | "Lifts" (more technically, "binds") an @'Auto' m a ('Maybe' b)@ into
-- an @'Auto' m ('Maybe' a) ('Maybe' b)@
--
-- The given 'Auto' is "run" only on the 'Just' inputs, and paused on
-- 'Nothing' inputs.
--
-- It's kind of like 'during', but the resulting @'Maybe' ('Maybe' b))@ is
-- "joined" back into a @'Maybe' b@.
--
-- prop> bindI a == fmap join (during a)
--
-- This very important combinator allows you to properly "chain" ("bind")
-- together series of inhibiting 'Auto's.  If you have an @'Auto'
-- m a ('Maybe' b)@ and an @'Auto' m b ('Maybe' c)@, you can chain them
-- into an @'Auto' m a ('Maybe' c)@.
--
-- @
--     f             :: 'Auto' m a ('Maybe' b)
--     g             :: 'Auto' m b ('Maybe' c)
--     'bindI' g . f :: 'Auto' m a ('Maybe' c)
-- @
--
-- (Users of libraries with built-in inhibition semantics like Yampa and
-- netwire might recognize this as the "default" composition in those other
-- libraries)
--
-- As a contrived example, how about an 'Auto' that only allows values
-- through during a window...between, say, the second and fourth steps:
--
-- >>> let window start finish = bindI (onFor finish) . offFor start
-- >>> let a = window 2 4 . count
-- >>> let Output res _ = stepAutoN 5 a ()
-- >>> res
-- [Nothing, Just 2, Just 3, Just 4, Nothing, Nothing]
--
-- (Remember that 'count' is the 'Auto' that ignores its input and displays
-- the current step count, starting with 1)
--
bindI :: Monad m => Auto m a (Maybe b) -> Auto m (Maybe a) (Maybe b)
bindI = fmap join . during
