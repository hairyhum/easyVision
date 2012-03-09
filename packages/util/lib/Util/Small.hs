{-# LANGUAGE FlexibleInstances, FlexibleContexts #-}
--{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FunctionalDependencies #-}
--{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
-----------------------------------------------------------------------------
{- |
Module      :  Util.Small
Copyright   :  (c) Alberto Ruiz 2006-12
License     :  GPL

Maintainer  :  Alberto Ruiz (aruiz at um dot es)
Stability   :  provisional

Small vectors.

-}
-----------------------------------------------------------------------------

module Util.Small
(
    Vectorlike(..), Dim2(..),Dim3(..),Dim4(..), Build, (!), (#),
    Matrixlike(..),
    Dim2x2,Dim3x3,Dim4x4,Dim3x4
) where

import Numeric.LinearAlgebra(Vector,fromList,(@>),(><),fromRows)
import Foreign.Storable
import Foreign.Ptr
import Util.Misc(Mat,Vec)

----------------------------------------------------------------------

class Vectorlike a
  where
    toVector :: a -> Vec
    unsafeFromVector :: Vec -> a

class GVectorlike a
  where
    toVectorG :: Storable t => a t -> Vector t
    unsafeFromVectorG :: Storable t => Vector t -> a t

instance GVectorlike a => Vectorlike (a Double)
   where
     toVector = toVectorG
     unsafeFromVector = unsafeFromVectorG



data Dim2 a = D2 !a !a        deriving (Eq, Show, Read)
data Dim3 a = D3 !a !a !a     deriving (Eq, Show, Read)
data Dim4 a = D4 !a !a !a !a  deriving (Eq, Show, Read)



class Build p e g | e p -> g, g -> e, g -> p
  where
    build :: p -> e -> g

infixl 3 !
(!) :: Build p e g => p -> e -> g
(!) = build

infixl 2 #
(#) :: Build p e g => p -> e -> g
(#) = build

instance Build a a (Dim2 a) where
    build = D2

instance Build (Dim2 a) a (Dim3 a) where
    build (D2 x y) a = D3 x y a

instance Build (Dim3 a) a (Dim4 a) where
    build (D3 x y z) a = D4 x y z a



instance GVectorlike Dim2 where
    toVectorG (D2 x1 x2) = fromList [x1,x2]
    unsafeFromVectorG v = D2 (v@>0) (v@>1)

instance GVectorlike Dim3 where
    toVectorG (D3 x1 x2 x3) = fromList [x1,x2,x3]
    unsafeFromVectorG v = D3 (v@>0) (v@>1) (v@>2)

instance GVectorlike Dim4 where
    toVectorG (D4 x1 x2 x3 x4) = fromList [x1,x2,x3,x4]
    unsafeFromVectorG v = D4 (v@>0) (v@>1) (v@>2) (v@>3)


{-
class Listable t where
    toList :: t a -> [a]
    unsafeFromList :: [a] -> t a

instance Listable Dim2 where
    toList (Dim2 x y) = [x,y]
    unsafeFromList [x,y] = Dim2 x y

instance Listable Dim3 where
    toList (Dim3 x y z) = [x,y,z]
    unsafeFromList [x,y,z] = Dim3 x y z

instance Listable Dim4 where
    toList (Dim4 x y z w) = [x,y,z,w]
    unsafeFromList [x,y,z,w] = Dim4 x y z w
-}

-- copied from storable-complex

instance Storable t => Storable (Dim2 t) where
    sizeOf _ = 2*sizeOf (undefined :: t)
    alignment _ = alignment (undefined :: t)
    peek p = do
        let q = castPtr p
        a <- peek q
        b <- peekElemOff q 1
        return (D2 a b)
    poke p (D2 a b) = do
        let q = (castPtr p)
        poke q a
        pokeElemOff q 1 b


instance Storable t => Storable (Dim3 t) where
    sizeOf _ = 3*sizeOf (undefined :: t)
    alignment _ = alignment (undefined :: t)
    peek p = do
        let q = castPtr p
        a <- peek q
        b <- peekElemOff q 1
        c <- peekElemOff q 2
        return (D3 a b c)
    poke p (D3 a b c) = do
        let q = (castPtr p)
        poke q a
        pokeElemOff q 1 b
        pokeElemOff q 2 c

instance Storable t => Storable (Dim4 t) where
    sizeOf _ = 4*sizeOf (undefined :: t)
    alignment _ = alignment (undefined :: t)
    peek p = do
        let q = castPtr p
        a <- peek q
        b <- peekElemOff q 1
        c <- peekElemOff q 2
        d <- peekElemOff q 3
        return (D4 a b c d)
    poke p (D4 a b c d) = do
        let q = (castPtr p)
        poke q a
        pokeElemOff q 1 b
        pokeElemOff q 2 c
        pokeElemOff q 3 d

--------------------------------------------------------------------------------

class Matrixlike a where
    type MatrixShape  (m :: *)
    toMatrix :: a -> Mat
    unsafeFromMatrix :: Mat -> a
    mkTrans :: (MatrixElem (MatrixShape a)) => MatrixShape a -> a
    mkTrans = unsafeFromMatrix . fromElements

----------------------------------------------------------------------

matrix2x2 :: Dim2 (Dim2 Double) -> Mat
matrix2x2 (D2 (D2 x1 x2)
              (D2 x3 x4) ) = (2><2) [x1,x2,
                                     x3,x4]

matrix3x3 :: Dim3 (Dim3 Double) -> Mat
matrix3x3 (D3 (D3 x1 x2 x3)
              (D3 x4 x5 x6)
              (D3 x7 x8 x9) ) = (3><3) [x1,x2,x3,
                                            x4,x5,x6,
                                            x7,x8,x9]

matrix3x4 :: Dim3 (Dim4 Double) -> Mat
matrix3x4 (D3 r1 r2 r3) = fromRows (map toVector [r1,r2,r3])

matrix4x4 :: Dim4 (Dim4 Double) -> Mat
matrix4x4 (D4 r1 r2 r3 r4) = fromRows (map toVector [r1,r2,r3,r4])

--type family MatrixShape  (m :: *)

type Dim2x2 = Dim2 (Dim2 Double)
type Dim3x3 = Dim3 (Dim3 Double)
type Dim3x4 = Dim3 (Dim4 Double)
type Dim4x4 = Dim4 (Dim4 Double)


class MatrixElem t where
    fromElements :: t -> Mat

instance MatrixElem Dim3x3 where
    fromElements = matrix3x3

instance MatrixElem Dim2x2 where
    fromElements = matrix2x2

instance MatrixElem Dim3x4 where
    fromElements = matrix3x4

instance MatrixElem Dim4x4 where
    fromElements = matrix4x4
