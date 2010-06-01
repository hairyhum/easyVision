{-# LANGUAGE ViewPatterns #-}

-----------------------------------------------------------------------------
{- |
Module      :  Vision.Camera
Copyright   :  (c) Alberto Ruiz 2006-7
License     :  GPL-style

Maintainer  :  Alberto Ruiz (aruiz at um dot es)
Stability   :  very provisional
Portability :  hmm...

Projective camera synthesis and analysis

-}
-----------------------------------------------------------------------------

module Vision.Camera
( CameraParameters(..)
, syntheticCamera
, easyCamera
, cameraAtOrigin
, factorizeCamera
, sepCam
, poseFromFactorization
, poseFromCamera
, homogZ0
, focalFromHomogZ0
, cameraFromHomogZ0
, poseFromHomogZ0
, cameraFromPlane
, kgen
, knor
, cameraOutline
, drawCameras
, toCameraSystem
, estimateCamera
, estimateCameraRaw
, rectifierFromCircularPoint
, rectifierFromAbsoluteDualConic
, estimateAbsoluteDualConic
, focalFromCircularPoint
, circularConsistency
, cameraModelOrigin
, projectionAt, projectionAtF
, projectionDerivAt, projectionDerivAtF
, epipolarMiniJac
, projectionDerivAt'
, auxCamJac, auxCamJacK
, projectionAt'', projectionAt'
) where

import Numeric.LinearAlgebra hiding (Matrix, Vector)
import qualified Numeric.LinearAlgebra as LA
import qualified Numeric.GSL as G
import Vision.Geometry
import Vision.Estimation(homogSystem, withNormalization, estimateHomography)
import Util.Stat
import Data.List(transpose,nub,maximumBy,genericLength,elemIndex, genericTake, sort)
import System.Random
import Debug.Trace(trace)
import Graphics.Plot(gnuplotWin)

debug' f x = trace (show $ f x) x
debug x = debug' id x

type Matrix = LA.Matrix Double
type Vector = LA.Vector Double

matrix = fromLists :: [[Double]] -> Matrix
vector = fromList ::  [Double] -> Vector
diagl = diag . vector

norm x = pnorm PNorm2 x

cameraAtOrigin = (ident 3 :: Matrix) <|> vector [0,0,0]

-- | A nice camera parameterization.
data CameraParameters 
    = CamPar { focalDist                      :: Double
             , panAngle, tiltAngle, rollAngle :: Double
             , cameraCenter                   :: (Double,Double,Double)
             } deriving Show


-- | Computes the camera parameters given the projection center,
--   the point imaged in the image center and roll angle.
easyCamera :: Double                   -- ^ field of view
           -> (Double,Double,Double)   -- ^ camera center
           -> (Double,Double,Double)   -- ^ a point in front of the camera
           -> Double                   -- ^ roll angle
           -> CameraParameters
easyCamera fov cen@(cx,cy,cz) pun@(px,py,pz) rho  = 
    CamPar { focalDist = f
           , panAngle = beta
           , tiltAngle = alpha
           , rollAngle = rho
           , cameraCenter = cen
           } where 
    dx = px-cx
    dy = py-cy
    dz = pz-cz
    dh = sqrt (dx*dx+dy*dy)
    f = 1 / tan (fov/2)
    beta = atan2 (-dx) dy
    alpha = atan2 dh (-dz) 

-- | Obtains the 3x4 homogeneous transformation from world points to image points.
syntheticCamera :: CameraParameters -> Matrix
syntheticCamera campar = flipx <> k <> r <> m where
    CamPar {focalDist = f, 
            panAngle = p, tiltAngle = t, rollAngle = q,
            cameraCenter = (cx,cy,cz)} = campar
    m = matrix [[1,0,0, -cx],
                [0,1,0, -cy],
                [0,0,1, -cz]]
    r = rotPTR (p,t,q)
    k = kgen f

flipx = diag (vector [-1,1,1])

-- | Matrix of intrinsic parameters of a diag(f,f,1) camera
kgen :: Double -> Matrix
kgen f = matrix [[f,0,0],
                 [0,f,0],
                 [0,0,1]]


rotPTR (pan,tilt,roll) = matrix
   [[-cb*cg + ca*sb*sg, -cg*sb - ca*cb*sg, -sa*sg],
    [ ca*cg*sb + cb*sg, -ca*cb*cg + sb*sg, -cg*sa],
    [            sa*sb,            -cb*sa,     ca]]
   where cb = cos pan 
         sb = sin pan 
         ca = cos tilt
         sa = sin tilt
         cg = cos roll
         sg = sin roll


focal' c = res where
    n = c <> mS <> trans c <> linf
    d = c <> mA <> trans c <> linf
    x = c <> mF <> trans c <> linf
    xi = inHomog x
    ni = inHomog n
    f = sqrt $ norm (xi - ni) ^2 - norm ni ^2
    res = if f > 0 then Just f else Nothing 

-- | Tries to compute the focal dist of a camera given the homography Z0 -> image
focalFromHomogZ0 :: Matrix -> Maybe Double
focalFromHomogZ0 c = res where
    [a11,a12,a13, 
     a21,a22,a23, 
     a31,a32,a33] = toList (flatten c)
    nix = (a11*a31 + a12 *a32)/den 
    niy = (a21*a31 + a22 *a32)/den
    xix = (a12 *(-a31 + a32) + a11 *(a31 + a32))/den
    xiy = (a22 *(-a31 + a32) + a21 *(a31 + a32))/den
    den = a31^2 + a32^2
    f = sqrt $ (xix-nix)^2 +(xiy-niy)^2 - nix^2 - niy^2
    res = if f > 0 then Just f else Nothing

-- | Obtains the pose of a factorized camera. (To do: check that is not in the floor).
poseFromFactorization :: (Matrix,Matrix,Vector)  -- ^ (k,r,c) as obtained by factorizeCamera
                         -> CameraParameters
poseFromFactorization (k,r,c) = cp where
    cp = CamPar {focalDist = f,
                 panAngle = -beta,
                 tiltAngle = alpha,
                 rollAngle = -rho,
                 cameraCenter = (cx, cy, cz) }
    f = (k@@>(0,0)+k@@>(1,1))/2 -- hmm
    [cx,cy,cz] = toList c
    [r1,r2,r3] = toColumns r
    h = fromColumns [r1,r2,-r<>c]
    b = trans h <> linf
    beta = atan2 (b@>0) (b@>1)
    n = k <> h <> mS <> b
    ni = inHomog n
    rho = atan2 (ni@>0) (ni@>1)
    alpha = atan2 f (norm ni)

-- | Extracts the camera parameters of a diag(f,f,1) camera
poseFromCamera :: Matrix               -- ^ 3x4 camera matrix
                  -> CameraParameters
poseFromCamera = poseFromFactorization . factorizeCamera

-- | Tries to extract the pose of the camera from the homography of the floor
poseFromHomogZ0 :: Maybe Double      -- ^ focal distance (if known)
           -> Matrix                      -- ^ 3x3 floor to image homography
           -> Maybe CameraParameters      -- ^ solution (the one above the floor)
poseFromHomogZ0 mbf = fmap poseFromCamera . cameraFromHomogZ0 mbf

--degree = pi / 180

extractColumns cs = trans . extractRows cs . trans

-- | Obtains the homography floor (Z=0) to image from a camera
homogZ0 :: Matrix -> Matrix
homogZ0 cam = extractColumns [0,1,3] cam

-- | Recovers a camera matrix from the homography floor (Z=0) to image. There are actually two solutions, above and below the ground. We return the camera over the floor
cameraFromHomogZ0 :: Maybe Double              -- ^ focal distance (if known)
           -> Matrix                           -- ^ 3x3 floor to image homography
           -> Maybe Matrix                     -- ^ 3x4 camera matrix (solution over the floor)
cameraFromHomogZ0 mbf c = res where
    mf = case mbf of
            Nothing -> focalFromHomogZ0 c     -- unknown, we try to estimate it
            jf -> jf                          -- given, use it
    res = case mf of
            Just f -> Just m      -- solution
            Nothing -> Nothing    -- cannot be estimated
    Just f = mf
    s = kgen (1/f) <> c
    [s1,s2,s3] = toColumns s
    sc = norm s1
    t = s3 / scalar sc
    r1 = unitary s1
    r3 = unitary (cross s1 s2)
    r2 = cross r3 r1
    rot1 = fromColumns [r1,r2,r3]
    cen1 = - (trans rot1 <> t)
    m1 = kgen f <> (fromColumns [r1,r2,r3] <|> t)
    m2 = kgen f <> (fromColumns [-r1,-r2,r3] <|> -t)
    m = if cen1@>2 > 0 then m1 else m2





cameraOutline f =
    [
    [0::Double,0,0],
    [1,0,0],
    [0,0,0],
    [0,0.75,0],
    [0,0,0],
    [-1,1,f],
    [1,1,f],
    [1,-1,f],
    [-1,-1,f],
    [-1,1,f],
    [0,0,0],
    [1,1,f],
    [0,0,0],
    [-1,-1,f],
    [0,0,0],
    [1,-1,f],
    [0,0,0]
    --,[0,0,3*f]
    ]

toCameraSystem cam = (inv m, f) where
    (k,r,c) = factorizeCamera cam
    m = (r <|> -r <> c) <-> vector [0,0,0,1]
    (f:_):_ = toLists k

doublePerp (a,b) (c,d) = (e,f) where
    a' = vector a
    b' = vector b
    c' = vector c
    d' = vector d
    v = cross (b'-a') (d'-c')
    coef = fromColumns [b'-a', v, c'-d']
    term = c'-a'
    [lam,mu,ep] = toList (inv coef <> term)
    e = toList $ a' + scalar lam * (b'-a')
    f = toList $ a' + scalar lam * (b'-a') + scalar mu * v

------------------------------------------------------            

-- -- | The RQ decomposition, written in terms of the QR. 
-- rq :: Matrix -> (Matrix,Matrix) 
-- rq m = (r,q) where
--     (q',r') = qr $ trans $ rev1 m
--     r = rev2 (trans r')
--     q = rev2 (trans q')
--     rev1 = flipud . fliprl
--     rev2 = fliprl . flipud


-- | Given a camera matrix m it returns (K, R, C)
--   such as m \=\~\= k \<\> r \<\> (ident 3 \<\|\> -c)
factorizeCamera :: Matrix -> (Matrix,Matrix,Vector)
factorizeCamera m = (normat3 k, signum (det r) `scale` r ,c) where
    m' = takeColumns 3 m
    (k',r') = rq m'
    s = diag(signum (takeDiag k'))
    (_,_,v) = svd m
    (v',_) = qr v
    k = k'<>s
    r = s<>r'
    c = inHomog $ flatten $ dropColumns 3 v'


-- | Factorize a camera matrix as (K, [R|t])
sepCam :: Matrix -> (Matrix, Matrix)
sepCam m = (k,p) where
    (k,r,c) = factorizeCamera m
    p = fromBlocks [[r,-r <> asColumn c]]

-- | Scaling of pixel coordinates to get values of order of 1
knor :: (Int,Int) -> Matrix
knor (szx,szy) = (3><3) [-a, 0, a,
                          0,-a, b,
                          0, 0, 1]
    where a = fromIntegral szx/2
          b = fromIntegral szy/2


estimateCameraRaw image world = h where
    eqs = concat (zipWith eq image world)
    h = reshape 4 $ fst $ homogSystem eqs
    eq [bx,by] [ax,ay,az] = 
        [[  0,  0,  0,  0,t15,t16,t17,t18,t19,t110,t111,t112],
         [t21,t22,t23,t24,  0,  0,  0,  0,t29,t210,t211,t212],
         [t31,t32,t33,t34,t35,t36,t37,t38,  0,   0,   0,   0]] where
            t15 =(-ax)
            t16 =(-ay)
            t17 =(-az)
            t18 =(-1)
            t19 =by*ax 
            t110=by*ay 
            t111=by*az
            t112=by
            t21 =ax 
            t22 =ay 
            t23 =az
            t24 =1
            t29 =(-bx*ax) 
            t210=(-bx*ay)
            t211=(-bx*az) 
            t212=(-bx)
            t31=(-by*ax) 
            t32=(-by*ay) 
            t33=(-by*az)
            t34=(-by)
            t35=bx*ax 
            t36=bx*ay
            t37=bx*az
            t38=bx     

estimateCamera = withNormalization inv estimateCameraRaw 

----------------------------------------------------------

-- | Estimation of a camera matrix from image - world correspondences, for world points in the plane z=0. We start from the closed-form solution given by 'estimateHomography' and 'cameraFromHomogZ0', and then optimize the camera parameters by minimization (using the Nelder-Mead simplex algorithm) of reprojection error.
cameraFromPlane :: Double        -- ^ desired precision in the solution (e.g., 1e-3)
                -> Int           -- ^ maximum number of iterations (e.g., 300)
                -> Maybe Double  -- ^ focal dist, if known
                -> [[Double]]    -- ^ image points as [x,y]
                -> [[Double]]    -- ^ world points in plane z=0, as [x,y]
                -> Maybe (Matrix, Matrix)  -- ^ 3x4 camera matrix and optimization path
cameraFromPlane prec nmax mbf image world = c where
    h = estimateHomography image world
    c = case cameraFromHomogZ0 mbf h of
        Nothing -> Nothing
        Just p  -> Just $ refine prec nmax p mimage mworld
                     where refine = case mbf of Nothing -> refineCamera1
                                                _       -> refineCamera2
    mimage = fromLists image
    mworld = fromLists (map pl0 world)
    pl0 [x,y] = [x,y,0]


refineCamera1 prec nmax cam mview mworld = (betterCam,path) where
    initsol = par2list $ poseFromCamera cam
    (betterpar, path) = minimize (cost mview mworld) initsol
    betterCam = syntheticCamera $ list2par betterpar
    cost view world lpar = pnorm PNorm2 $ flatten (view - htm c world)
        where c = syntheticCamera $ list2par lpar
    minimize f xi = G.minimize G.NMSimplex2 prec nmax  [0.01,5*degree,5*degree,5*degree,0.1,0.1,0.1] f xi

refineCamera2 prec nmax cam mview mworld = (betterCam,path) where
    f:initsol = par2list $ poseFromCamera cam
    (betterpar, path) = minimize (cost mview mworld) initsol
    betterCam = syntheticCamera $ list2par (f:betterpar)
    cost view world lpar = {-# SCC "cost2" #-} pnorm PNorm2 $ flatten (view - htm c world)
        where c = syntheticCamera $ list2par (f:lpar)
    minimize f xi = G.minimize G.NMSimplex2 prec nmax [5*degree,5*degree,5*degree,0.1,0.1,0.1] f xi

list2par [f,p,t,r,cx,cy,cz] = CamPar f p t r (cx,cy,cz)
par2list (CamPar f p t r (cx,cy,cz)) = [f,p,t,r,cx,cy,cz]

----------------------------------------------------------

-- Metric rectification tools

rectifierFromCircularPoint :: (Complex Double, Complex Double) -> Matrix
rectifierFromCircularPoint (x,y) = rectifierFromAbsoluteDualConic omega where
    cir = fromList [x,y,1]
    omega = fst $ fromComplex $ cir `outer` conj cir + conj cir `outer` cir

rectifierFromAbsoluteDualConic :: Matrix -> Matrix
rectifierFromAbsoluteDualConic omega = inv t where
    (_,s,u) = svd omega
    [s1,s2,_] = toList s
    s' = fromList [s1,s2,1]
    t = u <> diag (sqrt s')
    -- 0 =~= norm $ (normat3 $ t <> diagl [1,1,0] <> trans t) - (normat3 omega)

-- | from pairs of images of orthogonal lines
estimateAbsoluteDualConic ::  [([Double],[Double])] -> Maybe Matrix
estimateAbsoluteDualConic pls = clean where
    con = (3><3) [a,c,d
                 ,c,b,e
                 ,d,e,f]
    [a,b,c,d,e,f] = toList $ fst $ homogSystem $ eqs
    eqs = map eq pls
    eq ([a,b,c],[a',b',c']) = [a*a', b*b', a*b'+a'*b, c*a'+a*c', c*b'+c'*b, c*c']
    (l,v) = eigSH' con
    ls@[l1,l2,l3] = toList l
    ok = length pls >= 5 && (l1>0 && l2>0 || l2<0 && l3<0)
    di = if l2>0 then diagl [l1,l2,0] else diagl [0,-l2,-l3]
    clean | ok        = Just $ v <> di <> trans v
          | otherwise = Nothing

focalFromCircularPoint :: (Complex Double,Complex Double) -> Double
focalFromCircularPoint (cx,cy) = x * sqrt (1-(y/x)^2) where
    j' = fromList [cx,cy]
    pn = fst $ fromComplex j'
    x = norm (complex pn - j')
    y = norm pn
    -- alpha = asin (y/x)

-- | Consistency with diag(f,f,1) camera.
circularConsistency :: (Complex Double, Complex Double) -> Double
circularConsistency (x,y) = innerLines n0 h where
    n0 = fromList[realPart x, realPart y, 1] `cross` fromList[0,0,1]
    h = snd $ fromComplex $ cross jh (conj jh)
    jh = fromList [x,y,1]

innerLines l m = (l.*.m)/ sqrt (l.*.l) / sqrt(m.*.m)
    where a.*.b = a <> mS <.> b

--------------------------------------------------------------------------------
-- camera parameterization and Jacobian

cameraModelOrigin (Just k0) m = (k0,r0,cx0,cy0,cz0) where
    (_,r0,c) = factorizeCamera m
    [cx0,cy0,cz0] = toList c

cameraModelOrigin Nothing m = (k0,r0,cx0,cy0,cz0) where
    (k,r0,c) = factorizeCamera m
    [f1,f2,_] = toList (takeDiag k)
    k0 = kgen ((f1+f2)/2)
    [cx0,cy0,cz0] = toList c

projectionAt m f = \[p,t,r,cx,cy,cz] -> k0 <> rot1 p  <> rot2 t  <> rot3 r  <> r0 <> desp34 (cx0+cx) (cy0+cy) (cz0+cz)
    where (k0,r0,cx0,cy0,cz0) = cameraModelOrigin f m

projectionAtF m f = \[g,p,t,r,cx,cy,cz] -> kgen g <> k0 <> rot1 p  <> rot2 t  <> rot3 r  <> r0 <> desp34 (cx0+cx) (cy0+cy) (cz0+cz)
    where (k0,r0,cx0,cy0,cz0) = cameraModelOrigin f m

projectionDerivAt k0 r0 cx0 cy0 cz0 p t r cx cy cz x y z = ms where
    r1 = rot1 p
    r2 = rot2 t
    r3 = rot3 r
    a = k0 <> r1
    b =  a <> r2
    c =  b <> r3
    d =  c <> r0
    e = vector [x-cx0-cx, y-cy0-cy, z-cz0-cz]
    m0 = d <> e
    m4 = d <> vector [-1,0,0]
    m5 = d <> vector [0,-1,0]
    m6 = d <> vector [0,0,-1]
    m7 = -m4
    m8 = -m5
    m9 = -m6
    f = r0 <> e
    m3 = b <> rot3d r <> f
    g = r3 <> f
    m2 = a <> rot2d t <> g
    m1 = k0 <> rot1d p <> r2 <> g
    m0l = toList m0
    ms = iH m0l : map (derIH m0l . toList) [m1,m2,m3,m4,m5,m6,m7,m8,m9]

projectionDerivAtF k0 r0 cx0 cy0 cz0 f' p t r cx cy cz x y z = ms where
    r1 = rot1 p
    r2 = rot2 t
    r3 = rot3 r
    u = kgen f' <> k0
    a =  u <> r1
    b =  a <> r2
    c =  b <> r3
    d =  c <> r0
    e = vector [x-cx0-cx, y-cy0-cy, z-cz0-cz]
    m0 = d <> e
    m4 = d <> vector [-1,0,0]
    m5 = d <> vector [0,-1,0]
    m6 = d <> vector [0,0,-1]
    m7 = -m4
    m8 = -m5
    m9 = -m6
    f = r0 <> e
    m3 = b <> rot3d r <> f
    g = r3 <> f
    m2 = a <> rot2d t <> g
    h = r2 <> g
    m1 = u <> rot1d p <> h
    mf = diagl[1,1,0] <> k0 <> r1 <> h
    m0l = toList m0
    ms = iH m0l : map (derIH m0l . toList) [mf,m1,m2,m3,m4,m5,m6,m7,m8,m9]

derIH [x,y,w] [xd,yd,wd] = [ (xd*w-x*wd)/w^2 , (yd*w-y*wd)/w^2 ]
iH [x,y,w] = [x/w,y/w]

---------------------------------------------------------------

projectionAt'' (_,r0,cx0,cy0,cz0) = f where
    f (toList -> [p,t,r,cx,cy,cz]) = rot1 p  <> rot2 t  <> rot3 r  <> r0 <> desp34 (cx0+cx) (cy0+cy) (cz0+cz)


projectionAt' (k0,r0,cx0,cy0,cz0) = f where
    f (toList -> [p,t,r,cx,cy,cz]) = k0 <> rot1 p  <> rot2 t  <> rot3 r  <> r0 <> desp34 (cx0+cx) (cy0+cy) (cz0+cz)


auxCamJacK (k0,r0,cx0,cy0,cz0) (toList -> [p,t,r,cx,cy,cz]) = (rt,rt1,rt2,rt3,m4,m5,m6,cx+cx0,cy+cy0,cz+cz0) where
    r1 = rot1 p
    r2 = rot2 t
    r3 = rot3 r
    a = k0 <> r1
    b =  a <> r2
    c =  b <> r3
    d =  c <> r0
    rt = d
    [m4,m5,m6] = toColumns (-d)
    rt3 = b <> rot3d r <> r0
    g = r3 <> r0
    rt2 = a <> rot2d t <> g
    rt1 = k0 <> rot1d p <> r2 <> g


auxCamJac (_,r0,cx0,cy0,cz0) (toList -> [p,t,r,cx,cy,cz]) = (rt,rt1,rt2,rt3,m4,m5,m6,cx+cx0,cy+cy0,cz+cz0) where
    r1 = rot1 p
    r2 = rot2 t
    r3 = rot3 r
    b =  r1 <> r2
    c =  b <> r3
    d =  c <> r0
    rt = d
    [m4,m5,m6] = toColumns (-d)
    rt3 = b <> rot3d r <> r0
    g = r3 <> r0
    rt2 = r1 <> rot2d t <> g
    rt1 = rot1d p <> r2 <> g


projectionDerivAt' (rt,rt1,rt2,rt3,m4,m5,m6,cx,cy,cz) (toList -> [x',y',z']) = result where
    e = fromList [x'-cx, y'-cy, z'-cz]
    m0 = rt <> e
    m1 = rt1 <> e
    m2 = rt2 <> e
    m3 = rt3 <> e
    m7 = -m4
    m8 = -m5
    m9 = -m6
    [x,y,w] = toList m0
    d1 = recip w
    d2 = -x/w^2
    d3 = -y/w^2
    deriv = (2><3) [d1, 0,  d2,
                    0 , d1, d3 ]
    result = (fromList [x/w,y/w],
              deriv <> fromColumns [m1,m2,m3,m4,m5,m6],
              deriv <> fromColumns [m7,m8,m9])


epipolarMiniJac (r,r1,r2,r3,_,_,_,cx,cy,cz) (q,q1,q2,q3,_,_,_,dx,dy,dz) = result where
    c21 = fromList [dx-cx,dy-cy,dz-cz]
    t = unitary c21
    t1 = derNor c21 (fromList [1,0,0])
    t2 = derNor c21 (fromList [0,1,0])
    t3 = derNor c21 (fromList [0,0,1])

    a = q <> asMat t

    f = a <> trans r

    f1 = a <> trans r1
    f2 = a <> trans r2
    f3 = a <> trans r3

    f10 = q <> asMat t1 <> trans r
    f11 = q <> asMat t2 <> trans r
    f12 = q <> asMat t3 <> trans r
    f4 = -f10
    f5 = -f11
    f6 = -f12

    b = asMat t <> trans r

    f7 = q1 <> b
    f8 = q2 <> b
    f9 = q3 <> b

    g = fromColumns . map (flatten . trans)

    result =  (g [f], g [f1,f2,f3,f4,f5,f6], g [f7,f8,f9,f10,f11,f12])

derNor v w = scale nv w + scale (-(w<.>v)*vv*nv) v
    where vv = recip (v <.> v)
          nv = sqrt vv

--------------------------------------------------

-- shcam :: Matrix Double -> [[Double]]
-- shcam p = c where
--    (h,f) = toCameraSystem p
--    c = ht (h <> diag (fromList [1,1,1,5])) (cameraOutline f)
-- 
-- drawCameras :: String -> [Matrix Double] -> [[Double]] -> IO ()
-- drawCameras tit ms pts = do
--   let cmd = map (f.shcam) ms
--       f c = (c,"notitle 'c1' with lines 1")
-- 
--   gnuplotpdf tit
--          (  "set view 72,200; "
--          ++ "set xlabel '$x$'; set ylabel '$y$'; set zlabel '$z$';"
--          ++ "set size ratio 1;"
--          ++ "set notics;"
--          ++ "splot ")
--          (cmd ++ [(pts,"notitle 'v' with points 3")])

shcam :: Matrix -> [[Double]]
shcam p = c where
   (h,f) = toCameraSystem p
   c = ht (h <> diag (fromList [1,1,1,15])) (cameraOutline' f)

drawCameras :: String -> [Matrix] -> [[Double]] -> IO ()
drawCameras tit ms pts = do
  let cmd = map (f.shcam) ms
      f c = (c,"notitle 'c1' with lines 1")

  gnuplotWin tit
         (  "set view 72,200; "
         ++ "set pointsize 0.1;"
         ++ "set xlabel 'x'; set ylabel 'y'; set zlabel 'z';"
         ++ "set xrange [-2:2]; set yrange [-2:2]; set zrange [-2:2];"
         ++ "set size ratio 1;"
         ++ "set ticslevel 0;"
         ++ "set notics;"
         ++ "splot ")
         (cmd ++ [(pts,"notitle 'v' with points 7")])

cameraOutline' f =  [0::Double,0,0] : drop 5 (cameraOutline f)
