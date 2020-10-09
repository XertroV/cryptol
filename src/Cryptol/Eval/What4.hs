-- |
-- Module      :  Cryptol.Eval.What4
-- Copyright   :  (c) 2020 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com

{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
module Cryptol.Eval.What4
  ( What4(..)
  , W4Result(..)
  , W4Eval
  , w4Eval
  , Value
  , primTable
  , floatPrims
  ) where


import           Control.Monad (join)
import           Control.Monad.IO.Class
import qualified Data.Map as Map
import           Data.Map (Map)

import qualified What4.Interface as W4

import Cryptol.Backend
import Cryptol.Backend.What4
import qualified Cryptol.Backend.What4.SFloat as W4

import Cryptol.Eval.Generic
import Cryptol.Eval.Type (finNat')
import Cryptol.Eval.Value

import Cryptol.TypeCheck.Solver.InfNat( Nat'(..) )
import Cryptol.Testing.Random( randomV )
import Cryptol.Utils.Ident

-- See also Cryptol.Prims.Eval.primTable
primTable :: W4.IsSymExprBuilder sym => What4 sym -> Map.Map PrimIdent (Value sym)
primTable sym@(What4 w4sym _) =
  Map.union (floatPrims sym) $
  Map.fromList $ map (\(n, v) -> (prelPrim n, v))

  [ -- Literals
    ("True"        , VBit (bitLit sym True))
  , ("False"       , VBit (bitLit sym False))
  , ("number"      , ecNumberV sym) -- Converts a numeric type into its corresponding value.
                                    -- { val, rep } (Literal val rep) => rep
  , ("fraction"    , ecFractionV sym)
  , ("ratio"       , ratioV sym)

    -- Zero
  , ("zero"        , VPoly (zeroV sym))

    -- Logic
  , ("&&"          , binary (andV sym))
  , ("||"          , binary (orV sym))
  , ("^"           , binary (xorV sym))
  , ("complement"  , unary  (complementV sym))

    -- Ring
  , ("fromInteger" , fromIntegerV sym)
  , ("+"           , binary (addV sym))
  , ("-"           , binary (subV sym))
  , ("negate"      , unary (negateV sym))
  , ("*"           , binary (mulV sym))

    -- Integral
  , ("toInteger"   , toIntegerV sym)
  , ("/"           , binary (divV sym))
  , ("%"           , binary (modV sym))
  , ("^^"          , expV sym)
  , ("infFrom"     , infFromV sym)
  , ("infFromThen" , infFromThenV sym)

    -- Field
  , ("recip"       , recipV sym)
  , ("/."          , fieldDivideV sym)

    -- Round
  , ("floor"       , unary (floorV sym))
  , ("ceiling"     , unary (ceilingV sym))
  , ("trunc"       , unary (truncV sym))
  , ("roundAway"   , unary (roundAwayV sym))
  , ("roundToEven" , unary (roundToEvenV sym))

    -- Word operations
  , ("/$"          , sdivV sym)
  , ("%$"          , smodV sym)
  , ("lg2"         , lg2V sym)
  , (">>$"         , sshrV sym)

    -- Cmp
  , ("<"           , binary (lessThanV sym))
  , (">"           , binary (greaterThanV sym))
  , ("<="          , binary (lessThanEqV sym))
  , (">="          , binary (greaterThanEqV sym))
  , ("=="          , binary (eqV sym))
  , ("!="          , binary (distinctV sym))

    -- SignedCmp
  , ("<$"          , binary (signedLessThanV sym))

    -- Finite enumerations
  , ("fromTo"      , fromToV sym)
  , ("fromThenTo"  , fromThenToV sym)

    -- Sequence manipulations
  , ("#"          , -- {a,b,d} (fin a) => [a] d -> [b] d -> [a + b] d
     nlam $ \ front ->
     nlam $ \ back  ->
     tlam $ \ elty  ->
     lam  $ \ l     -> return $
     lam  $ \ r     -> join (ccatV sym front back elty <$> l <*> r))

  , ("join"       ,
     nlam $ \ parts ->
     nlam $ \ (finNat' -> each)  ->
     tlam $ \ a     ->
     lam  $ \ x     ->
       joinV sym parts each a =<< x)

  , ("split"       , ecSplitV sym)

  , ("splitAt"    ,
     nlam $ \ front ->
     nlam $ \ back  ->
     tlam $ \ a     ->
     lam  $ \ x     ->
       splitAtV sym front back a =<< x)

  , ("reverse"    , nlam $ \_a ->
                    tlam $ \_b ->
                     lam $ \xs -> reverseV sym =<< xs)

  , ("transpose"  , nlam $ \a ->
                    nlam $ \b ->
                    tlam $ \c ->
                     lam $ \xs -> transposeV sym a b c =<< xs)

    -- Shifts and rotates
  , ("<<"          , logicShift sym "<<"  shiftShrink
                        (w4bvShl w4sym) (w4bvLshr w4sym)
                        shiftLeftReindex shiftRightReindex)
  , (">>"          , logicShift sym ">>"  shiftShrink
                        (w4bvLshr w4sym) (w4bvShl w4sym)
                        shiftRightReindex shiftLeftReindex)
  , ("<<<"         , logicShift sym "<<<" rotateShrink
                        (w4bvRol w4sym) (w4bvRor w4sym)
                        rotateLeftReindex rotateRightReindex)
  , (">>>"         , logicShift sym ">>>" rotateShrink
                        (w4bvRor w4sym) (w4bvRol w4sym)
                        rotateRightReindex rotateLeftReindex)

    -- Indexing and updates
  , ("@"           , indexPrim sym (indexFront_int sym) (indexFront_bits sym) (indexFront_word sym))
  , ("!"           , indexPrim sym (indexBack_int sym) (indexBack_bits sym) (indexBack_word sym))

  , ("update"      , updatePrim sym (updateFrontSym_word sym) (updateFrontSym sym))
  , ("updateEnd"   , updatePrim sym (updateBackSym_word sym)  (updateBackSym sym))

    -- Misc

  , ("foldl"       , foldlV sym)
  , ("foldl'"      , foldl'V sym)

  , ("deepseq"     ,
      tlam $ \_a ->
      tlam $ \_b ->
       lam $ \x -> pure $
       lam $ \y ->
         do _ <- forceValue =<< x
            y)

  , ("parmap"      , parmapV sym)

  , ("fromZ"       , fromZV sym)

    -- {at,len} (fin len) => [len][8] -> at
  , ("error"       ,
      tlam $ \a ->
      nlam $ \_ ->
      VFun $ \s -> errorV sym a =<< (valueToString sym =<< s))

  , ("random"      ,
      tlam $ \a ->
      wlam sym $ \x ->
         case wordAsLit sym x of
           Just (_,i)  -> randomV sym a i
           Nothing -> cryUserError sym "cannot evaluate 'random' with symbolic inputs")

     -- The trace function simply forces its first two
     -- values before returing the third in the symbolic
     -- evaluator.
  , ("trace",
      nlam $ \_n ->
      tlam $ \_a ->
      tlam $ \_b ->
       lam $ \s -> return $
       lam $ \x -> return $
       lam $ \y -> do
         _ <- s
         _ <- x
         y)
  ]

-- | Table of floating point primitives
floatPrims :: W4.IsSymExprBuilder sym => What4 sym -> Map PrimIdent (Value sym)
floatPrims sym@(What4 w4sym _) =
  Map.fromList [ (floatPrim i,v) | (i,v) <- nonInfixTable ]
  where
  (~>) = (,)

  nonInfixTable =
    [ "fpNaN"       ~> fpConst (W4.fpNaN w4sym)
    , "fpPosInf"    ~> fpConst (W4.fpPosInf w4sym)
    , "fpFromBits"  ~> ilam \e -> ilam \p -> wlam sym \w ->
                       VFloat <$> liftIO (W4.fpFromBinary w4sym e p w)
    , "fpToBits"    ~> ilam \e -> ilam \p -> flam \x ->
                       pure $ VWord (e+p)
                            $ WordVal <$> liftIO (W4.fpToBinary w4sym x)
    , "=.="         ~> ilam \_ -> ilam \_ -> flam \x -> pure $ flam \y ->
                       VBit <$> liftIO (W4.fpEq w4sym x y)
    , "fpIsFinite"  ~> ilam \_ -> ilam \_ -> flam \x ->
                       VBit <$> liftIO do inf <- W4.fpIsInf w4sym x
                                          nan <- W4.fpIsNaN w4sym x
                                          weird <- W4.orPred w4sym inf nan
                                          W4.notPred w4sym weird

    , "fpAdd"       ~> fpBinArithV sym fpPlus
    , "fpSub"       ~> fpBinArithV sym fpMinus
    , "fpMul"       ~> fpBinArithV sym fpMult
    , "fpDiv"       ~> fpBinArithV sym fpDiv

    , "fpFromRational" ~>
       ilam \e -> ilam \p -> wlam sym \r -> pure $ lam \x ->
       do rat <- fromVRational <$> x
          VFloat <$> fpCvtFromRational sym e p r rat

    , "fpToRational" ~>
       ilam \_e -> ilam \_p -> flam \fp ->
       VRational <$> fpCvtToRational sym fp
    ]



-- | A helper for definitng floating point constants.
fpConst ::
  W4.IsSymExprBuilder sym =>
  (Integer -> Integer -> IO (W4.SFloat sym)) ->
  Value sym
fpConst mk =
     ilam \ e ->
 VNumPoly \ ~(Nat p) ->
 VFloat <$> liftIO (mk e p)
