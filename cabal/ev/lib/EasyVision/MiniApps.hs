-----------------------------------------------------------------------------
{- |
Module      :  EasyVision.MiniApps
Copyright   :  (c) Alberto Ruiz 2007
License     :  GPL-style

Maintainer  :  Alberto Ruiz (aruiz at um dot es)
Stability   :  very provisional
Portability :  hmm...

Useful windows with associated behaviour.

-}
-----------------------------------------------------------------------------

module EasyVision.MiniApps (
    readCatalog,
    getCatalog,
    catalogBrowser,
    hsvPalette,
    scatterWindow,
    regionDetector, regionTracker,
    panoramic,
    zoomer, zoomWindow,
    module EasyVision.MiniApps.Corners,
    module EasyVision.MiniApps.CornerTracker,
    module EasyVision.MiniApps.SignalMonitor,
    module EasyVision.MiniApps.Combinators,
    module EasyVision.MiniApps.Concurrent,
    module EasyVision.MiniApps.PoseTracker
)where

import Graphics.UI.GLUT as GL hiding (Size,Point,Matrix,matrix)
import EasyVision.GUI hiding (State)
import EasyVision.GUI.Parameters
import ImagProc hiding ((.*))
import ImagProc.Camera
import ImagProc.Util
import Features
import Data.List(transpose)
import Control.Monad(when)
import ImagProc.Ipp.Core
import Foreign.C.Types(CUChar)
import Foreign
import qualified Data.Map as Map
import Data.List(sort,nub,sortBy,minimumBy)
import Numeric.LinearAlgebra
import Classifier.Base(group)
import Data.IORef
import Vision
import Numeric.GSL.Minimization
import EasyVision.MiniApps.Combinators
import EasyVision.MiniApps.Concurrent
import Util.Kalman
import Text.Printf
import Data.Function(on)
import EasyVision.MiniApps.Corners
import EasyVision.MiniApps.CornerTracker
import EasyVision.MiniApps.SignalMonitor
import EasyVision.MiniApps.PoseTracker

-- | reads a labeled video
readCatalog :: String -> Size -> String -> Maybe Int -> (ImageYUV-> a) -> IO [(a,String)]
readCatalog video sz classesfile mbn prepro = do
    cam <- mplayer (video++" -benchmark") sz
    rawclasses <- readFile classesfile
    let classfilelines = lines rawclasses
        effectivelines = case mbn of
            Nothing -> classfilelines
            Just n  -> take n classfilelines
    let n = length effectivelines
        words' s = let (n:ws) = words s in [n , unwords ws]
    let [frames, classes] = transpose $ map words' effectivelines
    when (map read frames /= [1..n]) $ error ("inconsistent file "++ classesfile)
    imgs <- sequence (replicate n cam)
    return (zip (map prepro imgs) classes)

----------------------------------------------------------

classMap :: [[String]] -> String -> String
classMap lls = if null lls then id else search
    where f l@(h:_) = [(e,h)| e <- l]
          m = Map.fromList $ concatMap f lls
          search v = case Map.lookup v m of
                        Nothing -> v
                        Just c  -> c

-- | higher level version of getCatalog allowing for --group and --desired
getCatalog :: String -> Size -> String -> Maybe Int -> (ImageYUV-> a) -> IO [(a,String)]
getCatalog name sz lbs mbn feat = do
    dat <- readCatalog name sz lbs mbn feat

    group <- fmap classMap $ getOption "--group" []

    desi <- getFlag "desired"

    desired <- if not desi
                then fmap concat $ getOption "--group" []
                else getOption "--desired" []

    let okclasses = [(img, group cl) | (img,cl) <- dat, cl /= "?", desired == [] || cl `elem` desired]

    putStr "Valid images: "
    print (length okclasses)
    putStr "Classes found: "
    print (sort $ nub $ map snd okclasses)
    return okclasses


-- | to do (ImageYUV???)
catalogBrowser :: Int -> [(ImageYUV, String)] -> String -> Size -> IO (EVWindow (Int, [(ImageYUV, String)]))
catalogBrowser n catalog name sz =
    evWindow (n-1,catalog) name sz (Just disp) (mouse $ kbdQuit)
  where
    disp st = do
        (k,catalog) <- get st
        let (img,label) = catalog!!k
        drawImage img
        windowTitle $= name++" #"++show (k+1)++ ": "++label
    mouse _ st (MouseButton WheelUp) Down _ _ = do
        (k,catalog) <- get st
        st $= (min (k+1) (length catalog -1), catalog)
        postRedisplay Nothing
    mouse _ st (MouseButton WheelDown) Down _ _ = do
        (k,catalog) <- get st
        st $= (max (k-1) 0, catalog)
        postRedisplay Nothing
    mouse def _ a b c d = def a b c d

-------------------------------------------------------------------------------------

hsvPalette :: IO (EVWindow (CUChar, CUChar, CUChar))
hsvPalette = evWindow (128,128,255) "HSV" (Size 256 256) (Just disp) (mouse kbdQuit)
  where
    disp st = do
        (r',c',k) <- get st
        drawImage (palette k)
        pixelCoordinates (Size 256 256)
        setColor 0 0 0
        let r = fromIntegral r'
            c = fromIntegral c'
        renderPrimitive LineLoop $ mapM_ vertex
            [Pixel (r-2) (c-2), Pixel (r-2) (c+2), Pixel (r+2) (c+2), Pixel (r+2) (c-2)]
        text2D 20 20 (show (c,r,k))
    mouse _ st (MouseButton WheelUp) Down m _ = do
        (r,c,k) <- get st
        st $= (r,c,k + if GL.shift m == Down then 10 else 1)
        postRedisplay Nothing
    mouse _ st (MouseButton WheelDown) Down m _ = do
        (r,c,k) <- get st
        st $= (r,c,k- if GL.shift m == Down then 10 else 1)
        postRedisplay Nothing
    mouse _ st (MouseButton LeftButton) Down m (Position x y) = do
        (_,_,k) <- get st
        st $= (fromIntegral y, fromIntegral x,k)
        postRedisplay Nothing
    mouse def _ a b c d = def a b c d


palette k = hsvToRGB $ putChannels (fromLists ramp ,
                                    fromLists (transpose ramp),
                                    constImage k (Size 256 256))
    where
        ramp = replicate 256 [0..255]

        fromLists ls = unsafePerformIO $ do
            r <- image (Size 256 256)
            setData8u r ls
            return r

---------------------------------------------------------------------------

scatter examples (i,j) = do
    let (gs,lbs) = group examples
        plot = map (\v-> Point (v@>i) (v@>j))
        xs = map ((@>i).fst) examples
        ys = map ((@>j).fst) examples
        a1 = minimum xs
        a2 = maximum xs
        b1 = minimum ys
        b2 = maximum ys
        da = 0.05*(a2-a1)
        db = 0.05*(b2-b1)
        colors = [setColor 1 0 0, setColor 0 0 1, setColor 0 1 0] ++
                 [setColor 1 1 0, setColor 0 1 1, setColor 1 0 1] ++
                 [setColor 1 0.5 0.5, setColor 0.5 0.5 1, setColor 0.5 1 0.5] ++
                 repeat (setColor 1 1 1)
    clear [ColorBuffer]
    matrixMode $= Projection
    loadIdentity
    ortho2D (a1-da) (a2+da) (b1-db) (b2+db)
    matrixMode $= Modelview 0
    loadIdentity
    let f pts col = do
            col
            GL.renderPrimitive GL.Points . mapM_ GL.vertex . plot $ pts

    pointSize $= 3
    sequence_ $ zipWith f gs colors

    let text2D x y s = do
        rasterPos (Vertex2 x (y::GLdouble))
        renderString Helvetica12 s

    setColor 0.5 0.5 0.5
    text2D a2 b1 (show i)
    text2D a1 b2 (show j)


scatterWindow name sz exs coor  = do
    w <- evWindow coor name sz (Just disp) kbd
    return w
  where n = dim . fst . head $ exs
        disp rdesi = do
            coord <- get rdesi
            scatter exs coord

        kbd rdesi (SpecialKey KeyUp) Down _ _ = do
            (i,j) <- get rdesi
            rdesi $= (i,(j+1) `mod` n)
            postRedisplay Nothing
        kbd rdesi (SpecialKey KeyDown) Down _ _ = do
            (i,j) <- get rdesi
            rdesi $= (i, (j-1) `mod`n)
            postRedisplay Nothing
        kbd rdesi (SpecialKey KeyRight) Down _ _ = do
            (i,j) <- get rdesi
            rdesi $= ((i+1)`mod`n,j)
            postRedisplay Nothing
        kbd rdesi (SpecialKey KeyLeft) Down _ _ = do
            (i,j) <- get rdesi
            rdesi $= ((i-1) `mod` n,j)
            postRedisplay Nothing
        kbd _ a b c d = kbdQuit a b c d

-----------------------------------------------------------------------

getIntegral o name = fromIntegral `fmap` (getParam o name :: IO Int)

regionDetector :: String -> IO Channels -> IO (IO (Channels, Maybe (Point,[Point])))
regionDetector "" cam = do
    o <- createParameters [("kb",intParam 60  0 255),
                           ("kg",intParam 100 0 255),
                           ("kw",intParam 200 0 255),
                           ("c1",intParam 7 1 9),
                           ("c2",intParam 8 1 9)]
    return $ do
        kb <- getIntegral o "kb"
        kg <- getIntegral o "kg"
        kw <- getIntegral o "kw"
        c1 <- getIntegral o "c1"
        c2 <- getIntegral o "c2"
        orig <- cam
        let col = detectRange c1 c2 . hsvCode kb kg kw . hsv $ orig
            Size h w = size col
            area1 = 1
            area2 = 100
            pixarea1 = h*w*area1`div`1000
            pixarea2 = h*w*area2`div`1000
            rawconts = map (pixelsToPoints (size col). fst3) $
                       filter ((pixarea2>).snd3) $
                       sortBy (compare `on` (negate.snd3)) $
                       contours 20 pixarea1 1 True col
            conts = map momentsContour rawconts
            p = case conts of
                    [] -> Nothing
                    (x,y,_,_,_):_ -> Just (Point x y, head rawconts)
        return (orig, p)


regionDetector name cam = do
    e <- evWindow () name (mpSize 8) Nothing (const kbdQuit)
    cam' <- regionDetector "" cam
    return $ do
        (orig,pc) <- cam'
        inWin e $ do
            drawImage (rgb orig)
            setColor 1 1 1
            pointSize $= 5
            pointCoordinates (size (rgb orig))
            case pc of
                Just (p,cont) -> do
                    renderPrimitive Points $ mapM_ vertex [p]
                    renderPrimitive LineLoop $ mapM_ vertex cont
                Nothing -> return ()
        return (orig, pc)

detectRange a b = thresholdVal8u b 0 IppCmpGreater . thresholdVal8u a 0 IppCmpLess

fst3 (a,_,_) = a
snd3 (_,a,_) = a

----------------------------------------------------------------



-- | to do
regionTracker :: String -> IO (Channels,Maybe (Point,[Point])) -> IO (IO (Channels, (Int,Point,(Double,Double))))
regionTracker "" detector = do
    r <- newIORef s0
    rlost <- newIORef 0
    return $ do
        (orig,p) <- detector
        st <- get r
        lost <- get rlost
        let g (Point x y,_) = vector [x,y]
            st'@(State x c _) = kalman sys st (fmap g p)
        r $= st'
        let pt = Point (x@>0) (x@>1)
            v = (x@>2,x@>3)
        case p of
            Nothing -> rlost $= lost+1
            Just _  -> rlost $= 0
        return (orig, (lost,pt,v))

regionTracker name detector = do
    det <- regionTracker "" detector
    e <- evWindow () name (mpSize 8) Nothing (const kbdQuit)
    return $ do
        (orig, (lost,pt@(Point x y),v@(vx,vy))) <- det
        let pt2 = Point (x+vx) (y+vy)
        inWin e $ do
            drawImage (rgb orig)
            setColor 1 1 1
            pointSize $= 5
            pointCoordinates (size (rgb orig))
            renderPrimitive Points $ mapM_ vertex [pt]
            setColor 1 0 0
            lineWidth $= 2
            renderPrimitive Lines $ mapM_ vertex [pt,pt2]
        return (orig, (lost,pt,v))

-- Kalman filter for 2D position and velocity

vector l = fromList l :: Vector Double
matrix ls = fromLists ls :: Matrix Double
diagl = diag . vector

f = matrix [[1,0,1,0],
            [0,1,0,1],
            [0,0,1,0],
            [0,0,0,1]]

h = matrix [[1,0,0,0],
            [0,1,0,0]]

q = 1 * diagl [1,1,1,1]

r = 2 * diagl [1,1]

s0 = State (vector [0, 0, 0, 0]) (diagl [1, 1, 1, 1]) (vector [0,0])

sys = LinearSystem f h q r

------------------------------ ekf's check --------------

f' [x,y,vx,vy] = [ x+vx
                 , y+vy
                 , vx
                 , vy ]

h' [x,y,vx,vy ] = [x, y]

sys' = System f' h' q

-----------------------------------------------------------------------

-- | Creates a panoramic view from two cameras with (nearly) common camera center.
--
-- Left click: optimize
--
-- z: restart from identity
--
-- o: end optimization
panoramic :: Size              -- ^ of monitor window
          -> Double            -- ^ focal of base camera
          -> Double            -- ^ focal of source camera
          -> Double             -- ^ focal of virtual camera
          -> IO a               -- ^ base camera
          -> IO a               -- ^ source camera
          -> (a -> ImageFloat)  -- ^ how to extract the 'true image' from the cameras
          -> (a -> ImageFloat)           -- ^ how to extract the first argument to the similarity function
          -> (a -> ImageFloat)           -- ^ how to extract the second argument to the similarity function
          -> (ImageFloat -> ImageFloat -> Double) -- ^ the cost function
          -> IO (IO ImageFloat) -- ^ resulting virtual camera
panoramic sz fi1 fi2 fo camBase camAdj sel fa fb simil = do
    wMon <- evWindow (False,[0,0,0]) "autopanoramic" sz Nothing (mouse kbdQuit)
    wDeb <- evWindow () "debug" (mpSize 5) Nothing (const kbdQuit)
    wWar <- warper sz "control"
    return $ do
        img0raw <- camBase
        img1raw <- camAdj

        let img0 = sel img0raw
            img1 = sel img1raw

        (rh,_) <- getW wWar
        hi <- rh

        (opt,[pi,ti,ri]) <- getW wMon
        let [pan,tilt,roll] = if opt
                                then findRot (similgen fa fb simil) img0raw fi1 img1raw fi2 pi ti ri
                                else [pi,ti,ri]
            h = conjugateRotation pan tilt roll fi2 fi1
        putW wMon (opt,[pan,tilt,roll])
        let base = warp 0 (size img0) (hi<>kgen (fo/fi1)) img0
        warpOn' (hi<>kgen (fo/fi1)<>h) base img1 -- FIXME
        inWin wMon $ drawImage base
        inWin wDeb $ drawImage (fb img1raw)
        return base
  where
    -- click to adjust
    mouse _ st (MouseButton LeftButton) Down _ _ = do
        (_,p) <- get st
        st $= (True,p)

    -- restart from identity
    mouse _ st (Char 'z') Down _ _ = do
        st $= (True,[0,0,0])

    -- end optimization
    mouse _ st (Char 'o') Down _ _ = do
        (_,p) <- get st
        st $= (False,p)

    mouse def _ a b c d = def a b c d



similgen fa fb dab a h b = if ok roi then simil0 else 1E10
    where ia = fa a
          ib = fb b
          p = warp 0 (size ia) h ib
          roi = effectiveROI (size ia) h
          ok r = r1 r >= 0 && r2 r > 50 + r1 r && c1 r >= 0 && c2 r > 50 + c1 r
          simil0 = k * dab (f ia) (f p) --  sum32f (abs32f (f ia |*| f p))
              where f = modifyROI (const roi)
                    k = recip $ fromIntegral $ validArea (f ia)

effectiveROI sz h = newroi where
    r = 3/4
    trrec = pointsToPixels sz . map lp $ ht h [[1,-r], [1,r], [-1, r], [-1, -r]]
    newroi = intersection (fullroi sz)
                    ROI {r1 = (minimum $ map row trrec), c1 = (minimum $ map col trrec),
                         r2 = (maximum $ map row trrec), c2 = (maximum $ map col trrec) }

    fullroi (Size h w) = ROI {r1=0, r2=h-1, c1=0, c2=w-1}
    lp [x,y] = Point x y




conjugateRotation pan tilt rho fi fo =
        kgen fo <> rot1 tilt <> rot2 pan <> rot3 rho <> kgen (1/fi)

cost simil a fa b fb [pan, tilt, roll] = simil a h b
    where h = conjugateRotation pan tilt roll fb fa

findRot simil a fa b fb pi ti ri = fst $ minimize NMSimplex2 1E-3 30 [0.1*degree, 0.1*degree,0.1*degree] (cost simil a fa b fb) [pi,ti,ri]

-----------------------------------------------------------------------

-- | Creates a \"zoom\" window, in which we can easily observe pixel values. When the zoom level is very large numeric pixel values
--   are also shown. The function returns an update function to change the image to be zoomed (in the same location as the previous one).
--
-- click: center pixel
--
-- mouse wheel: zoom in and zoom out
--
-- q: destroy this window (only)

zoomer :: String        -- ^ window title
       -> Int          -- ^ size in pixels of the zoom window
       -> ImageGray    -- ^ initial image to analyze
       -> IO (ImageGray -> IO ()) -- ^ update function
zoomer title szz img0 = do
    w <- evWindow (img0,Pixel (h`div`2) (w`div`2),z0,True)
                  title isz (Just disp) (mouse kbdQuit)
    let f im = do
            (_,p,z,ok) <- getW w
            when ok $ do                 -- inWin w, disp (evSt w) hmm
                putW w (im,p,z,ok)
                postRedisplay (Just (evW w))
    return f
    where
    isz = Size szz szz
    Size h w = size img0
    s2 = (szz-1) `div` 2
    z0 = min h w `div` 2
    disp st = do
        k@(img,p,z,_) <- get st
        let roi = roiFromPixel z p
            imgz = modifyROI (const roi) img
        drawImage $ resize8u InterpNN isz imgz
        pointCoordinates isz
        setColor 0.4 0 0
        when (z>12) renderAxes
        when (z<=12) $ do
            pixelCoordinates (Size (2*z+1) (2*z+1))
            let ROI r1 r2 c1 c2 = theROI imgz
                v = fromIntegral (2*z+1) / fromIntegral szz
                dx = 0.5 - 5*v
                dy = 0.5 + 5*v
            setColor 0.6 0.6 0.6
            renderPrimitive Lines $ sequence_ [vertex (Pixel (r-r1) 0) >> vertex (Pixel (r-r1) (c2-c1+1)) |r<-[r1..r2]]
            renderPrimitive Lines $ sequence_ [vertex (Pixel 0 (c-c1)) >> vertex (Pixel (r2-r1+1) (c-c1)) |c<-[c1..c2]]
            setColor 0 0 0.7
            sequence_ [text2D' (fromIntegral (c-c1) +dx) (fromIntegral (r-r1) +dy) (show $ imgz `val8u` (Pixel r c)) |r<-[r1..r2],c<-[c1..c2]]
    mouse _ st (MouseButton WheelUp) Down _ _ = do
        (im,p,z,ok) <- get st
        st $= clip (im,p,z+(max 1 $ z`div`10),ok)
        postRedisplay Nothing
    mouse _ st (MouseButton WheelDown) Down _ _ = do
        (im,p,z,ok) <- get st
        st $= clip (im,p,z-(max 1 $ z`div`10),ok)
        postRedisplay Nothing
    mouse _ st (MouseButton LeftButton) Down _ (Position x y) = do
        (im,Pixel r c,z,ok) <- get st
        st $= clip (im, Pixel (r+(fromIntegral y-s2)*z`div`s2) (c+(fromIntegral x-s2)*z`div`s2) ,z, ok)
        postRedisplay Nothing
    mouse _ st (Char ' ') Down _ _ = do
        (im,Pixel r c,z,ok) <- get st
        st $= (im,Pixel r c,z, not ok)
        postRedisplay Nothing
    mouse _ st (Char 'q') Down _ _ = do
        Just w <- get currentWindow
        destroyWindow w
    mouse def _ a b c d = def a b c d

    clip (im,Pixel r c, z, ok) = (im,Pixel r' c', z', ok) where
        z' = max 1 $ min (min h w`div`2) $ z
        r' = max z' $ min (h-z'-1) $ r
        c' = max z' $ min (w-z'-1) $ c

    text2D' x y s = do
        rasterPos (Vertex2 x (y::GLfloat))
        renderString Helvetica10 s

-- | zoom window as a virtual camera
zoomWindow :: String -> Int -> (a -> ImageGray) -> IO a -> IO (IO a)
zoomWindow winname sz f cam = do
    i0 <- cam
    z <- zoomer winname sz (f i0)
    return $ do
        im <- cam
        z (f im)
        return im