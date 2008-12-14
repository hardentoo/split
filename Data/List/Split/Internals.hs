{-# LANGUAGE GADTs, Rank2Types, PatternGuards #-}
module Data.List.Split.Internals where

-- * Types and utilities

-- | A splitting strategy.
data Splitter a = Splitter { delimiter        :: Delimiter a
                               -- ^ What delimiter to split on
                           , delimPolicy      :: DelimPolicy
                               -- ^ What to do with delimiters (drop
                               --   from output, keep as separate
                               --   elements in output, or merge with
                               --   previous or following chunks)
                           , condensePolicy   :: CondensePolicy
                               -- ^ What to do with multiple
                               --   consecutive delimiters
                           , initBlankPolicy  :: EndPolicy
                               -- ^ Drop an initial blank chunk?
                           , finalBlankPolicy :: EndPolicy
                               -- ^ Drop a final blank chunk?
                           }

-- | The default splitting strategy: drop delimiters from the output,
--   don't condense multiple consecutive delimiters into one, keep
--   initial and final blank chunks.  Default delimiter is the
--   constantly false predicate.
--
--   XXX this isn't true! change default to keep instead of drop delimiters?
--
--   Overriding the delimiter of the 'defaultSplitter' strategy gives
--   a maximally information-preserving splitting strategy, in the
--   sense that (a) taking the 'concat' of the output yields the
--   original list, and (b) given only the output list, we can
--   reconstruct a 'Splitter' which would produce the same output list
--   again given the original input list.
--
--   This default strategy can be overridden in various ways to allow
--   discarding various sorts of information.
defaultSplitter :: Splitter a
defaultSplitter = Splitter { delimiter        = DelimEltPred (const False)
                           , delimPolicy      = Drop
                           , condensePolicy   = KeepBlankFields
                           , initBlankPolicy  = KeepBlank
                           , finalBlankPolicy = KeepBlank
                           }

-- | A delimiter can either be a predicate on elements, or a list of
--   elements to be matched as a subsequence.
data Delimiter a where
  DelimEltPred :: (a -> Bool) -> Delimiter a
  DelimSublist :: Eq a => [a] -> Delimiter a

-- | Try to match a delimiter at the start of a list, either failing
--   or decomposing the list into the portion which matched the delimiter
--   and the remainder.
matchDelim :: Delimiter a -> [a] -> Maybe ([a],[a])
matchDelim (DelimEltPred p) (x:xs) | p x       = Just ([x],xs)
                                   | otherwise = Nothing
matchDelim (DelimSublist []) xs = Just ([],xs)
matchDelim (DelimSublist _)  [] = Nothing
matchDelim (DelimSublist (d:ds)) (x:xs)
  | d == x = matchDelim (DelimSublist ds) xs >>= \(h,t) -> Just (d:h,t)
                                          {- -- $$ (fmap.first) (d:) -}
  | otherwise = Nothing

-- | What to do with delimiters?
data DelimPolicy = Drop      -- ^ Drop delimiters from the output.
                 | Keep      -- ^ Keep delimiters as separate chunks
                             --   of the output.
                 | KeepLeft  -- ^ Keep delimiters in the output,
                             --   prepending them to the following
                             --   chunk.
                 | KeepRight -- ^ Keep delimiters in the output,
                             --   appending them to the previous chunk.

-- | What to do with multiple consecutive delimiters?
data CondensePolicy = Condense         -- ^ Condense into a single delimiter.
                    | KeepBlankFields  -- ^ Insert blank chunks
                                       --   between consecutive
                                       --   delimiters.

-- | What to do with a blank chunk at either end of the list
--   (i.e. when the list begins or ends with a delimiter).
data EndPolicy = DropBlank | KeepBlank

-- | Tag sublists as delimiters or chunks.
data SplitElem a = Chunk [a] | Delim [a]
  deriving (Show, Eq)

-- | Internal representation of a split list that tracks which pieces
--   are delimiters and which aren't.
type SplitList a = [SplitElem a]

-- | Untag a 'SplitElem'.
fromElem :: SplitElem a -> [a]
fromElem (Chunk as) = as
fromElem (Delim as) = as

-- | Test whether a 'SplitElem' is a delimiter.
isDelim :: SplitElem a -> Bool
isDelim (Delim _) = True
isDelim _ = False

-- | Standard build function.
build :: (forall b. (a -> b -> b) -> b -> b) -> [a]
build g = g (:) []

-- * Implementation

-- | Given a delimiter to use, split a list into an internal
--   representation with sublists tagged as delimiters or chunks.
--   This transformation is lossless; in particular,
--   @concatMap fromElem (splitInternal d l) == l@.
splitInternal :: Delimiter a -> [a] -> SplitList a
splitInternal _ [] = []
splitInternal d xxs@(x:xs) | Just (match,rest) <- matchDelim d xxs = Delim match : splitInternal d rest
                   | otherwise = x `consChunk` splitInternal d xs
  where consChunk x (Chunk c : ys) = Chunk (x:c) : ys
        consChunk x ys             = Chunk [x] : ys

-- | Given a split list in the internal tagged representation, produce
--   the final output according to the strategy defined by the given
--   'Splitter'.
postProcess :: Splitter a -> SplitList a -> [[a]]
postProcess s = map fromElem
              . dropFinal (finalBlankPolicy s)
              . dropInitial (initBlankPolicy s)
              . mergeDelims (delimPolicy s)
              . dropDelims (delimPolicy s)
              . insertBlanks
              . condenseDelims (condensePolicy s)

-- | Drop delimiters if the 'DelimPolicy' is 'Drop'.
dropDelims :: DelimPolicy -> SplitList a -> SplitList a
dropDelims Drop l = [ c | c@(Chunk _) <- l ]
dropDelims _ l = l

-- | Condense multiple consecutive delimiters into one if the
--   'CondensePolicy' is 'Condense'.
condenseDelims :: CondensePolicy -> SplitList a -> SplitList a
condenseDelims KeepBlankFields l = l
condenseDelims Condense l = condense' l
  where condense' [] = []
        condense' (c@(Chunk _) : l) = c : condense' l
        condense' l = (Delim $ concatMap fromElem ds) : condense' rest
          where (ds,rest) = span isDelim l

-- | Insert blank chunks between any remaining consecutive delimiters,
--   and at the beginning/end if the first/last element is a
--   delimiter.
insertBlanks :: SplitList a -> SplitList a
insertBlanks [] = [Chunk []]
insertBlanks (d@(Delim _) : l) = Chunk [] : insertBlanks' (d:l)
insertBlanks l = insertBlanks' l

-- | Insert blank chunks between consecutive delimiters.
insertBlanks' :: SplitList a -> SplitList a
insertBlanks' [] = []
insertBlanks' (d1@(Delim _) : d2@(Delim _) : l) = d1 : Chunk [] : insertBlanks' (d2:l)
insertBlanks' [d@(Delim _)] = [d, Chunk []]
insertBlanks' (c : l) = c : insertBlanks' l

-- | Merge delimiters into adjacent chunks according to the 'DelimPolicy'.
mergeDelims :: DelimPolicy -> SplitList a -> SplitList a
mergeDelims KeepLeft = mergeLeft
mergeDelims KeepRight = mergeRight
mergeDelims _ = id

-- | Merge delimiters with adjacent chunks to the right (yes, that's
--   not a typo: the delimiters should end up on the left of the
--   chunks, so they are merged with chunks to their right).
mergeLeft :: SplitList a -> SplitList a
mergeLeft [] = []
mergeLeft ((Delim d) : (Chunk c) : l) = Chunk (d++c) : mergeLeft l
mergeLeft (c : l) = c : mergeLeft l

-- | Merge delimiters with adjacent chunks to the left.
mergeRight :: SplitList a -> SplitList a
mergeRight [] = []
mergeRight ((Chunk c) : (Delim d) : l) = Chunk (c++d) : mergeRight l
mergeRight (c : l) = c : mergeRight l

-- | Drop an initial blank chunk according to the given 'EndPolicy'.
dropInitial :: EndPolicy -> SplitList a -> SplitList a
dropInitial DropBlank (Chunk [] : l) = l
dropInitial _ l = l

-- | Drop a final blank chunk according to the given 'EndPolicy'.
dropFinal :: EndPolicy -> SplitList a -> SplitList a
dropFinal _ [] = []
dropFinal DropBlank l | Chunk [] <- last l = init l
dropFinal _ l = l

-- * Combinators

-- | Split a list according to the given splitting strategy.
split :: Splitter a -> [a] -> [[a]]
split s = postProcess s . splitInternal (delimiter s)

-- ** Basic strategies
--
-- $ All these basic strategies have the same parameters as the
-- 'defaultSplitter' except for the delimiters.

-- | A splitting strategy that splits on any one of the given
--   elements.  For example:
--
-- > split (oneOf "xyz") "aazbxyzcxd" == ["aa","b","","","c","d"]
oneOf :: Eq a => [a] -> Splitter a
oneOf elts = defaultSplitter { delimiter = DelimEltPred (`elem` elts) }

-- | A splitting strategy that splits on the given list, when it is
--   encountered as an exact subsequence.  For example:
--
-- > split (onSublist "xyz") "aazbxyzcxd" == ["aazb","cxd"]
onSublist :: Eq a => [a] -> Splitter a
onSublist lst = defaultSplitter { delimiter = DelimSublist lst }

-- | A splitting strategy that splits on any elements that satisfy the
--   given predicate.  For example:
--
-- > split (whenElt (<0)) [2,4,-3,6,-9,1] == [[2,4],[6],[1]]
whenElt :: (a -> Bool) -> Splitter a
whenElt p = defaultSplitter { delimiter = DelimEltPred p }

-- ** Strategy transformers

-- | Keep delimiters as their own separate lists in the output (the
--   default is to drop delimiters). For example,
--
-- > split (oneOf ":") "a:b:c" == ["a", "b", "c"]
-- > split (keepDelims $ oneOf ":") "a:b:c" == ["a", ":", "b", ":", "c"]
keepDelims :: Splitter a -> Splitter a
keepDelims s = s { delimPolicy = Keep }

-- | Keep delimiters in the output by prepending them to adjacent
--   chunks.  For example:
--
-- > split (keepDelimsL $ oneOf "xyz") "aazbxyzcxd" == ["aa","zb","x","y","zc","xd"]
keepDelimsL :: Splitter a -> Splitter a
keepDelimsL s = s { delimPolicy = KeepLeft }

-- | Keep delimiters in the output by appending them to adjacent
--   chunks. For example:
--
-- > split (keepDelimsR $ oneOf "xyz") "aazbxyzcxd" == ["aaz","bx","y","z","cx","d"]
keepDelimsR :: Splitter a -> Splitter a
keepDelimsR s = s { delimPolicy = KeepRight }

-- | Condense multiple consecutive delimiters into one.  For example:
--
-- > split (condense $ oneOf "xyz") "aazbxyzcxd" == ["aa","b","c","d"]
-- > split (condense . keepDelims $ oneOf "xyz") "aazbxyzcxd" == ["aa","z","b","xyz","c","x","d"]
condense :: Splitter a -> Splitter a
condense s = s { condensePolicy = Condense }

-- | Don't generate a blank chunk if there is a delimiter at the
--   beginning.  For example:
--
-- > split (oneOf ":") ":a:b" == ["","a","b"]
-- > split (dropInitBlank $ oneOf ":") ":a:b" == ["a","b"]
dropInitBlank :: Splitter a -> Splitter a
dropInitBlank s = s { initBlankPolicy = DropBlank }

-- | Don't generate a blank chunk if there is a delimiter at the end.
--   For example:
--
-- > split (oneOf ":") "a:b:" == ["a","b",""]
-- > split (dropFinalBlank $ oneOf ":") "a:b:" == ["a","b"]
dropFinalBlank :: Splitter a -> Splitter a
dropFinalBlank s = s { finalBlankPolicy = DropBlank }

-- ** Derived combinators

-- | Drop all blank chunks from the output.  Equivalent to
--   @dropInitBlank . dropFinalBlank . condense@.  For example:
--
-- > XXX example here
dropBlanks :: Splitter a -> Splitter a
dropBlanks = dropInitBlank . dropFinalBlank . condense

-- | Make a strategy that splits a list into chunks that all start
--   with the given subsequence.  Equivalent to @dropInitBlank
--   . keepDelimsL . onSublist@.  For example:
--
-- > split (startsWith "app") "applyappicativeapplaudapproachapple" == ["apply","appicative","applaud","approach","apple"]
startsWith :: Eq a => [a] -> Splitter a
startsWith = dropInitBlank . keepDelimsL . onSublist

-- | Make a strategy that splits a list into chunks that all start
--   with one of the given elements.  Equivalent to @dropInitBlank
--   . keepDelimsL . oneOf@.  For example:
--
-- > split (startsWithOneOf ['A'..'Z']) "ACamelCaseIdentifier" == ["A","Camel","Case","Identifier"]
startsWithOneOf :: Eq a => [a] -> Splitter a
startsWithOneOf = dropInitBlank . keepDelimsL . oneOf

-- | Make a strategy that splits a list into chunks that all end with
--   the given subsequence.  Equivalent to @dropFinalBlank
--   . keepDelimsR . onSublist@.  For example:
--
-- > split (endsWith "ly") "happilyslowlygnarlylily" == ["happily","slowly","gnarly","lily"]
endsWith :: Eq a => [a] -> Splitter a
endsWith = dropFinalBlank . keepDelimsR . onSublist

-- | Make a strategy that splits a list into chunks that all start
--   with one of the given elements.  Equivalent to @dropFinalBlank
--   . keepDelimsR . oneOf@.  For example:
--
-- > split (condense $ endsWithOneOf ".,?! ") "Hi, there!  How are you?" == ["Hi, ","there!  ","How ","are ","you?"]
endsWithOneOf :: Eq a => [a] -> Splitter a
endsWithOneOf = dropFinalBlank . keepDelimsR . oneOf

-- ** Convenience functions

-- | Split on any of the given elements.  Equivalent to @split . oneOf@.
splitOneOf :: Eq a => [a] -> [a] -> [[a]]
splitOneOf = split . oneOf

-- | Split on the given sublist.  Equivalent to @split . onSublist@.
splitOn :: Eq a => [a] -> [a] -> [[a]]
splitOn   = split . onSublist

-- | Split on elements satisfying the given predicate.  Equivalent to
--   @split . whenElt@.
splitWhen :: (a -> Bool) -> [a] -> [[a]]
splitWhen = split . whenElt

-- | A synonym for 'splitOn'.
sepBy :: Eq a => [a] -> [a] -> [[a]]
sepBy = splitOn

-- | A synonym for 'splitOneOf'.
sepByOneOf :: Eq a => [a] -> [a] -> [[a]]
sepByOneOf = splitOneOf

-- | Split into chunks terminated by the given subsequence.
--   Equivalent to @split . dropFinalBlank . onSublist@.
endBy :: Eq a => [a] -> [a] -> [[a]]
endBy = split . dropFinalBlank . onSublist

-- | Split into chunks terminated by one of the given elements.
--   Equivalent to @split . dropFinalBlank . oneOf@.
endByOneOf :: Eq a => [a] -> [a] -> [[a]]
endByOneOf = split . dropFinalBlank . oneOf

-- | A synonym for 'endBy'.  Note that this is the \"inverse\" of the
--   'intercalate' function from "Data.List", in the sense that
--   @unintercalate x (intercalate x l) == l@ for all lists @x@ and
--   @l@.
unintercalate :: Eq a => [a] -> [a] -> [[a]]
unintercalate = endBy

-- * Other splitting methods

splitEvery :: Int -> [e] -> [[e]]
splitEvery i l = map (take i) (build (splitter l)) where
  splitter [] _ n = n
  splitter l c n  = l `c` splitter (drop i l) c n

splitPlaces :: [Int] -> [e] -> [[e]]
splitPlaces ls xs = build (splitPlacer ls xs) where
  splitPlacer [] _ _ n      = n
  splitPlacer _ [] _ n      = n
  splitPlacer (l:ls) xs c n = let (x1, x2) = splitAt l xs in x1 `c` splitPlacer ls x2 c n

splitPowersOf2 :: [e] -> [[e]]
splitPowersOf2 = splitPlaces (iterate (*2) 1)
