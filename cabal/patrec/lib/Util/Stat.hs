-----------------------------------------------------------------------------
{- |
Module      :  Util.Stat
Copyright   :  (c) Alberto Ruiz 2006-7
License     :  GPL-style

Maintainer  :  Alberto Ruiz (aruiz at um dot es)
Stability   :  very provisional
Portability :  hmm...

Statistical characterization of multivariate samples and Principal Component Analysis.

-}
-----------------------------------------------------------------------------

module Util.Stat
( Stat(..)
, stat

, Codec(..)

, PCARequest(..)
, pca

, robustLocation
) where

import Numeric.LinearAlgebra hiding (eigenvalues)
import Data.List(transpose,sortBy,minimumBy)
import Data.Function(on)
import Util.Real(row,col,(&),(//))

-- | 1st and 2nd order statistics and other useful information extracted from a multivariate sample, where observations are given as rows of a matrix.

data Stat = Stat { meanVector              :: Vector Double
                 , covarianceMatrix        :: Matrix Double
                 , eigenvalues             :: Vector Double
                 , eigenvectors            :: Matrix Double
                 , invCov                  :: Matrix Double
                 , whitenedData            :: Matrix Double
                 , whiteningTransformation :: Matrix Double -- ^ homogeneous transformation which includes centering
                 , whitener                :: Matrix Double
                 , varianceVector          :: Vector Double
                 , normalizedData          :: Matrix Double
                 }

-- | Creates a 'Stat' structure from a matrix. Of course, due to laziness, only the fields required by the particular application will be actually computed.
stat :: Matrix Double -> Stat
stat x = s where
    m = mean x
    xc = x - row m
    c = (trans xc <> xc) / fromIntegral (rows x -1)
    (l,v') = eigSH' c
    v = trans v'
    lastrow = row $ fromList $ replicate (cols x) 0 ++ [1.0::Double]
    w = diag (1/sqrt l) <> v
    n = rows x
    n' = fromIntegral n / fromIntegral (n-1)
    vars = scalar n' * mean (xc^(2::Int))
    s = Stat { meanVector = m
             , covarianceMatrix = c
             , eigenvalues = l
             , eigenvectors = v
             , invCov = inv c
             , whitener = w
             , whiteningTransformation = w &  col (-w <> m) //
                                         lastrow
             , whitenedData = xc <> trans w
             , varianceVector = vars
             , normalizedData = (x - row m) / row (sqrt vars)
             }


----------------------------------------------------------------------

mean :: (Field t) => Matrix t -> Vector t
mean m = ones <> m
    where r = rows m
          k = 1 / fromIntegral r
          ones = constant k r

----------------------------------------------------------------------

-- | This structure contains functions to encode and decode individual vectors (or collection of vectors packed into a matrix) obtained by some suitable criterion (e.g. 'pca').

data Codec = 
    Codec { encodeVector :: Vector Double -> Vector Double
          , decodeVector :: Vector Double -> Vector Double
          , encodeMatrix :: Matrix Double -> Matrix Double
          , decodeMatrix :: Matrix Double -> Matrix Double
          , encodeList   :: [Double] -> [Double]
          , decodeList   :: [Double] -> [Double]
}

-- | Two ways to specify the amount of 'pca' compression.
data PCARequest = ReconstructionQuality Double -- ^ ratio of spectral power
                | NewDimension Int             -- ^ number of desired components

-- | Given the desired compression criterion, from the 'Stat'istics of a dataset it creates a linear 'Codec' based on principal component analysis  (which maximizes mean squared reconstruction error).
pca :: PCARequest -> Stat -> Codec

pca (NewDimension n) st =
    Codec { encodeVector = encv
          , decodeVector = decv
          , encodeMatrix = \x -> (x - row m) <> trans vp
          , decodeMatrix = \y -> (y <> vp) + row m
          , encodeList = toList . encv . fromList
          , decodeList = toList . decv . fromList
} where
    encv x = vp <> (x - m)
    decv x = (x <> vp) + m
    vp = takeRows n (eigenvectors st)
    m = meanVector st

pca (ReconstructionQuality prec) st = pca (NewDimension n) st where    
    s = toList (eigenvalues st)
    n = 1 + (length $ fst $ span (< (prec'*sum s)) $ cumSum s)
    cumSum = tail . scanl (+) 0.0
    prec' = if prec <=0.0 || prec >= 1.0
                then error "the reconstruction quality must be 0<prec<1"
                else prec

{- | PedroE's algorithm. For example, with @dist x y = abs (x-y)@ we have:

@> robustLocation dist [1,2,3,11,12,13,14,15::Double]
[(1.0,0.0),(1.0,1.0),(2.0,1.0),(12.0,2.0),(13.0,2.0),(11.0,8.0),(11.0,9.0),(11.0,10.0)]@

-}
robustLocation :: Ord b => (a -> a -> b) -> [a] -> [(a,b)]
robustLocation dis l = mins where
    mins = map (minimumBy (compare `on` snd)) dst
    dst = transpose ds
    ds = map getdis l
    getdis p = sortBy (compare `on` snd) [(p, dis p y) | y<-l]
