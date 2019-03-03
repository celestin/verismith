{-|
Module      : VeriFuzz.Gen
Description : Various useful generators.
Copyright   : (c) 2019, Yann Herklotz Grave
License     : GPL-3
Maintainer  : ymherklotz [at] gmail [dot] com
Stability   : experimental
Portability : POSIX

Various useful generators.
-}

{-# LANGUAGE TemplateHaskell #-}

module VeriFuzz.Gen
    ( -- * Generation methods
      procedural
    , fromGraph
    , randomMod
    )
where

import           Control.Lens                   hiding (Context)
import           Control.Monad                  (replicateM)
import           Control.Monad.Trans.Class      (lift)
import           Control.Monad.Trans.Reader     hiding (local)
import           Control.Monad.Trans.State.Lazy
import           Data.Foldable                  (fold)
import qualified Data.Text                      as T
import           Test.QuickCheck                (Gen)
import qualified Test.QuickCheck                as QC
import           VeriFuzz.AST
import           VeriFuzz.ASTGen
import           VeriFuzz.Internal
import           VeriFuzz.Mutate
import           VeriFuzz.Random

data Context = Context { _variables :: [Port]
--                       , _modules   :: [ModDecl]
                       }

makeLenses ''Context

data ProbModItem = ProbModItem { _probAssign :: {-# UNPACK #-} !Int
                               , _probAlways :: {-# UNPACK #-} !Int
                               }

--makeLenses ''ProbModItem

data Probabilities = Probabilities { _probModItem :: {-# UNPACK #-} !ProbModItem }

--makeLenses ''Probabilities

type StateGen =  StateT Context (ReaderT Probabilities Gen)

toId :: Int -> Identifier
toId = Identifier . ("w" <>) . T.pack . show

toPort :: Identifier -> Gen Port
toPort ident = do
    i <- abs <$> QC.arbitrary
    return $ wire i ident

sumSize :: [Port] -> Int
sumSize ports = sum $ ports ^.. traverse . portSize

random :: [Identifier] -> (Expr -> ContAssign) -> Gen ModItem
random ctx fun = do
    expr <- QC.sized (exprWithContext ctx)
    return . ModCA $ fun expr

--randomAssigns :: [Identifier] -> [Gen ModItem]
--randomAssigns ids = random ids . ContAssign <$> ids

randomOrdAssigns :: [Identifier] -> [Identifier] -> [Gen ModItem]
randomOrdAssigns inp ids = snd $ foldr generate (inp, []) ids
    where generate cid (i, o) = (cid : i, random i (ContAssign cid) : o)

randomMod :: Int -> Int -> Gen ModDecl
randomMod inps total = do
    x     <- sequence $ randomOrdAssigns start end
    ident <- sequence $ toPort <$> ids
    let inputs_ = take inps ident
    let other   = drop inps ident
    let y = ModCA . ContAssign "y" . fold $ Id <$> drop inps ids
    let yport   = [wire (sumSize other) "y"]
    return . declareMod other . ModDecl "test_module" yport inputs_ $ x ++ [y]
  where
    ids   = toId <$> [1 .. total]
    end   = drop inps ids
    start = take inps ids

fromGraph :: Gen ModDecl
fromGraph = do
    gr <- rDupsCirc <$> QC.resize 100 randomCircuit
    return
        $   initMod
        .   head
        $   nestUpTo 5 (generateAST gr)
        ^.. getVerilogSrc
        .   traverse
        .   getDescription

gen :: Gen a -> StateGen a
gen = lift . lift

proceduralContAssign :: StateGen ContAssign
proceduralContAssign = do
    name    <- gen QC.arbitrary
    size    <- gen positiveArb
    signed  <- gen QC.arbitrary
    context <- get
    variables %= (Port Wire signed size name :)
    ContAssign name
        <$> (   gen
            .   QC.sized
            .   exprWithContext
            $   context
            ^.. variables
            .   traverse
            .   portName
            )

proceduralModItem :: StateGen ModItem
proceduralModItem = ModCA <$> proceduralContAssign

proceduralPorts :: StateGen [Port]
proceduralPorts = do
    portList <- gen $ QC.listOf1 QC.arbitrary
    variables %= (<> portList)
    return portList

proceduralMod :: Bool -> StateGen ModDecl
proceduralMod top = do
    name     <- if top then return "top" else gen QC.arbitrary
    portList <- proceduralPorts
    amount   <- gen positiveArb
    mi       <- replicateM amount proceduralModItem
    context  <- get
    let local = filter (\p -> notElem p portList) $ context ^. variables
    let size  = sum $ local ^.. traverse . portSize
    let yport = Port Wire False size "y"
    return . declareMod local . ModDecl name [yport] portList $ combineAssigns
        yport
        mi

procedural :: Gen VerilogSrc
procedural =
    VerilogSrc
        .   (: [])
        .   Description
        <$> runReaderT (evalStateT (proceduralMod True) context) config
  where
    config  = Probabilities (ProbModItem 5 1)
    context = Context []
