{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Diagrams.Core.Compile
-- Copyright   :  (c) 2013 diagrams-core team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  diagrams-discuss@googlegroups.com
--
-- This module provides tools for compiling @QDiagrams@ into a more
-- convenient and optimized tree form, suitable for use by backends.
--
-----------------------------------------------------------------------------

module Diagrams.Core.Compile
  ( -- * Tools for backends
    RNode(..)
  , RTree
  , toRTree

  -- * Internals

  , toDTree
  , fromDTree
  )
  where

import qualified Data.List.NonEmpty      as NEL
import           Data.Maybe              (fromMaybe)
import           Data.Monoid.Coproduct
import           Data.Monoid.MList
import           Data.Semigroup
import           Data.Tree
import           Data.Tree.DUAL
import           Diagrams.Core.Style
import           Diagrams.Core.Transform
import           Diagrams.Core.Types

emptyDTree :: Tree (DNode b v a)
emptyDTree = Node DEmpty []

onStyle :: forall v. HasLinearMap v => (Style v -> Style v) -> DownAnnots v -> DownAnnots v
onStyle f = alt (fmap (mapR f :: Transformation v :+: Style v -> Transformation v :+: Style v))

-- | Convert a @QDiagram@ into a raw tree.
toDTree :: HasLinearMap v =>
             (Style v -> Style v) -> QDiagram b v m -> Maybe (DTree b v ())
toDTree f (QD qd)
  = foldDUAL

      -- Prims at the leaves.  We ignore the accumulated d-annotations
      -- for prims (since we instead distribute them incrementally
      -- throughout the tree as they occur), or pass them to the
      -- continuation in the case of a delayed node.
      (\d -> withQDiaLeaf

               -- Prim: make a leaf node
               (\p -> Node (DPrim p) [])

               -- Delayed tree: pass the accumulated d-annotations to
               -- the continuation, convert the result to a DTree, and
               -- splice it in, adding a DDelay node to mark the point
               -- of the splice.
               (Node DDelay . (:[]) . fromMaybe emptyDTree . toDTree f . ($ onStyle f d))
      )

      -- u-only leaves --> empty DTree. We don't care about the
      -- u-annotations.
      emptyDTree

      -- a non-empty list of child trees.
      (\ts -> case NEL.toList ts of
                [t] -> t
                ts' -> Node DEmpty ts'
      )

      -- Internal d-annotations.  We untangle the interleaved
      -- transformations and style, and carefully place the style
      -- /above/ the transform in the tree (since by calling
      -- 'untangle' we have already performed the action of the
      -- transform on the style).
      (\d t -> case get d of
                 Option Nothing   -> t
                 Option (Just d') ->
                   let (tr,sty) = untangle d'
                   in  Node (DStyle $ f sty) [Node (DTransform tr) [t]]
      )

      -- Internal a-annotations.
      (\a t -> Node (DAnnot a) [t])
      qd

-- | Convert a @DTree@ to an @RTree@ which can be used dirctly by backends.
--   A @DTree@ includes nodes of type @DTransform (Transformation v)@;
--   in the @RTree@ transform is pushed down until it reaches a primitive node.
fromDTree :: HasLinearMap v => DTree b v () -> RTree b v ()
fromDTree = fromDTree' mempty
  where
    fromDTree' :: HasLinearMap v => Transformation v -> DTree b v () -> RTree b v ()
    -- We put the accumulated transformation (accTr) and the prim
    -- into an RPrim node.
    fromDTree' accTr (Node (DPrim p) _)
      = Node (RPrim (transform accTr p)) []

    -- Styles are transformed then stored in their own node
    -- and accTr is push down the tree.
    fromDTree' accTr (Node (DStyle s) ts)
      = Node (RStyle (transform accTr s)) (fmap (fromDTree' accTr) ts)

    -- Transformations are accumulated and pushed down as well.
    fromDTree' accTr (Node (DTransform tr) ts)
      = Node REmpty (fmap (fromDTree' (accTr <> tr)) ts)

    -- Drop accumulated transformations upon encountering a DDelay
    -- node --- the tree unfolded beneath it already took into account
    -- any transformation at this point.
    fromDTree' _ (Node DDelay ts)
      = Node REmpty (fmap (fromDTree' mempty) ts)

    -- DAnnot and DEmpty nodes become REmpties, in the future my want to
    -- handle DAnnots separately if they are used, again accTr flows through.
    fromDTree' accTr (Node _ ts)
      = Node REmpty (fmap (fromDTree' accTr) ts)

-- | Compile a @QDiagram@ into an 'RTree', rewriting styles with the
-- given function along the way.  Suitable for use by backends when
-- implementing 'renderData'.  Styles must be rewritten before
-- converting to RTree in case a DelayedLeaf uses a modified
-- Attribute.
toRTree :: HasLinearMap v => (Style v -> Style v) -> QDiagram b v m -> RTree b v ()
toRTree f = fromDTree . fromMaybe (Node DEmpty []) . toDTree f
