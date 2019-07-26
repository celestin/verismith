{-|
Module      : VeriFuzz.Generate
Description : Various useful generators.
Copyright   : (c) 2019, Yann Herklotz
License     : GPL-3
Maintainer  : yann [at] yannherklotz [dot] com
Stability   : experimental
Portability : POSIX

Various useful generators.
-}

{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}

module VeriFuzz.Generate
    ( -- * Generation methods
      procedural
    , proceduralIO
    , proceduralSrc
    , proceduralSrcIO
    , randomMod
    )
where

import           Control.Lens                     hiding (Context)
import           Control.Monad                    (replicateM)
import           Control.Monad.Trans.Class        (lift)
import           Control.Monad.Trans.Reader       hiding (local)
import           Control.Monad.Trans.State.Strict
import           Data.Foldable                    (fold)
import           Data.Functor.Foldable            (cata)
import           Data.List                        (foldl', partition)
import qualified Data.Text                        as T
import           Hedgehog                         (Gen)
import qualified Hedgehog.Gen                     as Hog
import qualified Hedgehog.Range                   as Hog
import           VeriFuzz.Config
import           VeriFuzz.Internal
import           VeriFuzz.Verilog.AST
import           VeriFuzz.Verilog.BitVec
import           VeriFuzz.Verilog.Eval
import           VeriFuzz.Verilog.Internal
import           VeriFuzz.Verilog.Mutate

-- Temporary imports
import           Data.Char                        (toLower)
import           Debug.Trace
import           VeriFuzz.Verilog.CodeGen

data Context = Context { _variables   :: [Port]
                       , _parameters  :: [Parameter]
                       , _modules     :: [ModDecl]
                       , _nameCounter :: {-# UNPACK #-} !Int
                       , _stmntDepth  :: {-# UNPACK #-} !Int
                       , _modDepth    :: {-# UNPACK #-} !Int
                       , _determinism :: !Bool
                       }

makeLenses ''Context

type StateGen =  StateT Context (ReaderT Config Gen)

toId :: Int -> Identifier
toId = Identifier . ("w" <>) . T.pack . show

toPort :: Identifier -> Gen Port
toPort ident = do
    i <- range
    return $ wire i ident

sumSize :: [Port] -> Range
sumSize ps = sum $ ps ^.. traverse . portSize

random :: [Port] -> (Expr -> ContAssign) -> Gen ModItem
random ctx fun = do
    expr <- Hog.sized (exprWithContext (ProbExpr 1 1 0 1 1 1 1 0 1 1) [] ctx)
    return . ModCA $ fun expr

--randomAssigns :: [Identifier] -> [Gen ModItem]
--randomAssigns ids = random ids . ContAssign <$> ids

randomOrdAssigns :: [Port] -> [Port] -> [Gen ModItem]
randomOrdAssigns inp ids = snd $ foldr generate (inp, []) ids
  where
    generate cid (i, o) = (cid : i, random i (ContAssign (_portName cid)) : o)

randomMod :: Int -> Int -> Gen ModDecl
randomMod inps total = do
    ident <- sequence $ toPort <$> ids
    x     <- sequence $ randomOrdAssigns (start ident) (end ident)
    let inputs_ = take inps ident
    let other   = drop inps ident
    let y = ModCA . ContAssign "y" . fold $ Id <$> drop inps ids
    let yport   = [wire (sumSize other) "y"]
    return . declareMod other $ ModDecl "test_module"
                                        yport
                                        inputs_
                                        (x ++ [y])
                                        []
  where
    ids   = toId <$> [1 .. total]
    end   = drop inps
    start = take inps

gen :: Gen a -> StateGen a
gen = lift . lift

largeNum :: Gen Int
largeNum = Hog.int $ Hog.linear (-100) 100

wireSize :: Gen Int
wireSize = Hog.int $ Hog.linear 2 100

range :: Gen Range
range = Range <$> fmap fromIntegral wireSize <*> pure 0

genBitVec :: Gen BitVec
genBitVec = fmap fromIntegral largeNum

binOp :: Gen BinaryOperator
binOp = Hog.element
    [ BinPlus
    , BinMinus
    , BinTimes
        -- , BinDiv
        -- , BinMod
    , BinEq
    , BinNEq
        -- , BinCEq
        -- , BinCNEq
    , BinLAnd
    , BinLOr
    , BinLT
    , BinLEq
    , BinGT
    , BinGEq
    , BinAnd
    , BinOr
    , BinXor
    , BinXNor
    , BinXNorInv
        -- , BinPower
    , BinLSL
    , BinLSR
    , BinASL
    , BinASR
    ]

unOp :: Gen UnaryOperator
unOp = Hog.element
    [ UnPlus
    , UnMinus
    , UnNot
    , UnLNot
    , UnAnd
    , UnNand
    , UnOr
    , UnNor
    , UnXor
    , UnNxor
    , UnNxorInv
    ]

constExprWithContext :: [Parameter] -> ProbExpr -> Hog.Size -> Gen ConstExpr
constExprWithContext ps prob size
    | size == 0 = Hog.frequency
        [ (prob ^. probExprNum, ConstNum <$> genBitVec)
        , ( if null ps then 0 else prob ^. probExprId
          , ParamId . view paramIdent <$> Hog.element ps
          )
        ]
    | size > 0 = Hog.frequency
        [ (prob ^. probExprNum, ConstNum <$> genBitVec)
        , ( if null ps then 0 else prob ^. probExprId
          , ParamId . view paramIdent <$> Hog.element ps
          )
        , (prob ^. probExprUnOp, ConstUnOp <$> unOp <*> subexpr 2)
        , ( prob ^. probExprBinOp
          , ConstBinOp <$> subexpr 2 <*> binOp <*> subexpr 2
          )
        , ( prob ^. probExprCond
          , ConstCond <$> subexpr 2 <*> subexpr 2 <*> subexpr 2
          )
        , ( prob ^. probExprConcat
          , ConstConcat <$> Hog.nonEmpty (Hog.linear 0 10) (subexpr 2)
          )
        ]
    | otherwise = constExprWithContext ps prob 0
    where subexpr y = constExprWithContext ps prob $ size `div` y

exprSafeList :: ProbExpr -> [(Int, Gen Expr)]
exprSafeList prob = [(prob ^. probExprNum, Number <$> genBitVec)]

exprRecList :: ProbExpr -> (Hog.Size -> Gen Expr) -> [(Int, Gen Expr)]
exprRecList prob subexpr =
    [ (prob ^. probExprNum, Number <$> genBitVec)
    , ( prob ^. probExprConcat
      , Concat <$> Hog.nonEmpty (Hog.linear 0 10) (subexpr 2)
      )
    , (prob ^. probExprUnOp    , UnOp <$> unOp <*> subexpr 2)
    , (prob ^. probExprStr, Str <$> Hog.text (Hog.linear 0 100) Hog.alphaNum)
    , (prob ^. probExprBinOp   , BinOp <$> subexpr 2 <*> binOp <*> subexpr 2)
    , (prob ^. probExprCond    , Cond <$> subexpr 2 <*> subexpr 2 <*> subexpr 2)
    , (prob ^. probExprSigned  , Appl <$> pure "$signed" <*> subexpr 2)
    , (prob ^. probExprUnsigned, Appl <$> pure "$unsigned" <*> subexpr 2)
    ]

rangeSelect :: [Parameter] -> [Port] -> Gen Expr
rangeSelect ps ports = do
    p <- Hog.element ports
    let s = calcRange ps (Just 32) $ _portSize p
    msb <- Hog.int (Hog.constantFrom (s `div` 2) 0 (s - 1))
    lsb <- Hog.int (Hog.constantFrom (msb `div` 2) 0 msb)
    return . RangeSelect (_portName p) $ Range (fromIntegral msb)
                                               (fromIntegral lsb)

exprWithContext :: ProbExpr -> [Parameter] -> [Port] -> Hog.Size -> Gen Expr
exprWithContext prob ps [] n | n == 0 = Hog.frequency $ exprSafeList prob
                             | n > 0 = Hog.frequency $ exprRecList prob subexpr
                             | otherwise = exprWithContext prob ps [] 0
    where subexpr y = exprWithContext prob ps [] $ n `div` y
exprWithContext prob ps l n
    | n == 0
    = Hog.frequency
        $ (prob ^. probExprId, Id . fromPort <$> Hog.element l)
        : exprSafeList prob
    | n > 0
    = Hog.frequency
        $ (prob ^. probExprId         , Id . fromPort <$> Hog.element l)
        : (prob ^. probExprRangeSelect, rangeSelect ps l)
        : exprRecList prob subexpr
    | otherwise
    = exprWithContext prob ps l 0
    where subexpr y = exprWithContext prob ps l $ n `div` y

someI :: Int -> StateGen a -> StateGen [a]
someI m f = do
    amount <- gen $ Hog.int (Hog.linear 1 m)
    replicateM amount f

makeIdentifier :: T.Text -> StateGen Identifier
makeIdentifier prefix = do
    context <- get
    let ident = Identifier $ prefix <> showT (context ^. nameCounter)
    nameCounter += 1
    return ident

getPort' :: PortType -> Identifier -> [Port] -> StateGen Port
getPort' pt i c = case filter portId c of
    x : _ -> return x
    []    -> newPort i pt
    where portId (Port pt' _ _ i') = i == i' && pt == pt'

nextPort :: PortType -> StateGen Port
nextPort pt = do
    context <- get
    ident   <- makeIdentifier . T.toLower $ showT pt
    getPort' pt ident (_variables context)

newPort :: Identifier -> PortType -> StateGen Port
newPort ident pt = do
    p <- gen $ Port pt <$> Hog.bool <*> range <*> pure ident
    variables %= (p :)
    return p

scopedExpr :: StateGen Expr
scopedExpr = do
    context <- get
    prob    <- askProbability
    gen
        . Hog.sized
        . exprWithContext (_probExpr prob) (_parameters context)
        $ _variables context

contAssign :: StateGen ContAssign
contAssign = do
    expr <- scopedExpr
    p    <- nextPort Wire
    return $ ContAssign (p ^. portName) expr

lvalFromPort :: Port -> LVal
lvalFromPort (Port _ _ _ i) = RegId i

probability :: Config -> Probability
probability c = c ^. configProbability

askProbability :: StateGen Probability
askProbability = lift $ asks probability

assignment :: StateGen Assign
assignment = do
    expr <- scopedExpr
    lval <- lvalFromPort <$> nextPort Reg
    return $ Assign lval Nothing expr

seqBlock :: StateGen Statement
seqBlock = do
    stmntDepth -= 1
    tstat <- SeqBlock <$> someI 20 statement
    stmntDepth += 1
    return tstat

conditional :: StateGen Statement
conditional = do
    expr  <- scopedExpr
    nc    <- _nameCounter <$> get
    tstat <- seqBlock
    nc'   <- _nameCounter <$> get
    nameCounter .= nc
    fstat <- seqBlock
    nc''  <- _nameCounter <$> get
    nameCounter .= max nc' nc''
    return $ CondStmnt expr (Just tstat) (Just fstat)

forLoop :: StateGen Statement
forLoop = do
    num <- Hog.int (Hog.linear 0 20)
    var <- lvalFromPort <$> nextPort Reg
    ForLoop (Assign var Nothing 0)
            (BinOp (varId var) BinLT $ fromIntegral num)
            (Assign var Nothing $ BinOp (varId var) BinPlus 1)
        <$> seqBlock
    where varId v = Id (v ^. regId)

statement :: StateGen Statement
statement = do
    prob <- askProbability
    cont <- get
    let defProb i = prob ^. probStmnt . i
    Hog.frequency
        [ (defProb probStmntBlock              , BlockAssign <$> assignment)
        , (defProb probStmntNonBlock           , NonBlockAssign <$> assignment)
        , (onDepth cont (defProb probStmntCond), conditional)
        , (onDepth cont (defProb probStmntFor) , forLoop)
        ]
    where onDepth c n = if c ^. stmntDepth > 0 then n else 0

alwaysSeq :: StateGen ModItem
alwaysSeq = Always . EventCtrl (EPosEdge "clk") . Just <$> seqBlock

-- | Should resize a port that connects to a module port if the latter is
-- larger.  This should not cause any problems if the same net is used as input
-- multiple times, and is resized multiple times, as it should only get larger.
resizePort :: [Parameter] -> Identifier -> Range -> [Port] -> [Port]
resizePort ps i ra = foldl' func []
    where
        func l p@(Port t _ ri i')
            | i' == i && calc ri < calc ra = trace (fmap toLower (show t) <> " " <> show (GenVerilog i) <> ": " <> (show $ calc ri) <> " to " <> (show $ calc ra)) $ (p & portSize .~ ra) : l
            | otherwise = p : l
        calc = calcRange ps $ Just 64

-- | Instantiate a module, where the outputs are new nets that are created, and
-- the inputs are taken from existing ports in the context.
--
-- 1 is subtracted from the inputs for the length because the clock is not
-- counted and is assumed to be there, this should be made nicer by filtering
-- out the clock instead. I think that in general there should be a special
-- representation for the clock.
instantiate :: ModDecl -> StateGen ModItem
instantiate (ModDecl i outP inP _ _) = do
    context <- get
    outs    <- replicateM (length outP) (nextPort Wire)
    ins <- take (length inpFixed) <$> Hog.shuffle (context ^. variables)
    mapM_ (uncurry process) . zip (ins ^.. traverse . portName) $ inpFixed ^.. traverse . portSize
    ident <- makeIdentifier "modinst"
    vs <- view variables <$> get
    Hog.choice
        [ return . ModInst i ident $ ModConn <$> toE (outs <> clkPort <> ins)
        , ModInst i ident <$> Hog.shuffle
            (zipWith ModConnNamed (view portName <$> outP <> clkPort <> inpFixed) (toE $ outs <> clkPort <> ins))
        ]
    where
        toE ins = Id . view portName <$> ins
        (inpFixed, clkPort) = partition filterFunc inP
        filterFunc (Port _ _ _ n)
            | n == "clk" = False
            | otherwise = True
        process p r = do
            params <- view parameters <$> get
            variables %= resizePort params p r

-- | Generates a module instance by also generating a new module if there are
-- not enough modules currently in the context. It keeps generating new modules
-- for every instance and for every level until either the deepest level is
-- achieved, or the maximum number of modules are reached.
--
-- If the maximum number of levels are reached, it will always pick an instance
-- from the current context. The problem with this approach is that at the end
-- there may be many more than the max amount of modules, as the modules are
-- always set to empty when entering a new level. This is to fix recursive
-- definitions of modules, which are not defined.
--
-- One way to fix that is to also decrement the max modules for every level,
-- depending on how many modules have already been generated. This would mean
-- there would be moments when the module cannot generate a new instance but
-- also not take a module from the current context. A fix for that may be to
-- have a default definition of a simple module that is used instead.
--
-- Another different way to handle this would be to have a probability of taking
-- a module from a context or generating a new one.
modInst :: StateGen ModItem
modInst = do
    prob    <- lift ask
    context <- get
    let maxMods = prob ^. configProperty . propMaxModules
    if length (context ^. modules) < maxMods
        then do
            let currMods = context ^. modules
            let params   = context ^. parameters
            let vars     = context ^. variables
            modules .= []
            variables .= []
            parameters .= []
            modDepth -= 1
            chosenMod <- moduleDef Nothing
            ncont     <- get
            let genMods = ncont ^. modules
            modDepth += 1
            parameters .= params
            variables .= vars
            modules .= chosenMod : currMods <> genMods
            instantiate chosenMod
        else Hog.element (context ^. modules) >>= instantiate

-- | Generate a random module item.
modItem :: StateGen ModItem
modItem = do
    conf    <- lift ask
    let prob = conf ^. configProbability
    context <- get
    let defProb i = prob ^. probModItem . i
    det <- Hog.frequency [ (conf ^. configProperty . propDeterminism, return True)
                         , (conf ^. configProperty . propNonDeterminism, return False) ]
    determinism .= det
    Hog.frequency
        [ (defProb probModItemAssign   , ModCA <$> contAssign)
        , (defProb probModItemSeqAlways, alwaysSeq)
        , ( if context ^. modDepth > 0 then defProb probModItemInst else 0
          , modInst )
        ]

-- | Either return the 'Identifier' that was passed to it, or generate a new
-- 'Identifier' based on the current 'nameCounter'.
moduleName :: Maybe Identifier -> StateGen Identifier
moduleName (Just t) = return t
moduleName Nothing  = makeIdentifier "module"

-- | Generate a random 'ConstExpr' by using the current context of 'Parameters'.
constExpr :: StateGen ConstExpr
constExpr = do
    prob    <- askProbability
    context <- get
    gen . Hog.sized $ constExprWithContext (context ^. parameters)
                                           (prob ^. probExpr)

-- | Generate a random 'Parameter' and assign it to a constant expression which
-- it will be initialised to. The assumption is that this constant expression
-- should always be able to be evaluated with the current context of parameters.
parameter :: StateGen Parameter
parameter = do
    ident <- makeIdentifier "param"
    cexpr <- constExpr
    let param = Parameter ident cexpr
    parameters %= (param :)
    return param

-- | Evaluate a range to an integer, and cast it back to a range.
evalRange :: [Parameter] -> Int -> Range -> Range
evalRange ps n (Range l r) = Range (eval l) (eval r)
    where eval = ConstNum . cata (evaluateConst ps) . resize n

-- | Calculate a range to an int by maybe resizing the ranges to a value.
calcRange :: [Parameter] -> Maybe Int -> Range -> Int
calcRange ps i (Range l r) = eval l - eval r + 1
  where
    eval a = fromIntegral . cata (evaluateConst ps) $ maybe a (`resize` a) i

-- | Filter out a port based on it's name instead of equality of the ports. This
-- is because the ports might not be equal if the sizes are being updated.
identElem :: Port -> [Port] -> Bool
identElem p = elem (p ^. portName) . toListOf (traverse . portName)

-- | Generates a module definition randomly. It always has one output port which
-- is set to @y@. The size of @y@ is the total combination of all the locally
-- defined wires, so that it correctly reflects the internal state of the
-- module.
moduleDef :: Maybe Identifier -> StateGen ModDecl
moduleDef top = do
    name     <- moduleName top
    portList <- Hog.list (Hog.linear 4 10) $ nextPort Wire
    mi       <- Hog.list (Hog.linear 4 100) modItem
    ps       <- Hog.list (Hog.linear 0 10) parameter
    context  <- get
    config   <- lift ask
    let (newPorts, local) = partition (`identElem` portList) $ _variables context
    let
         size =
            evalRange (_parameters context) 32
                .   sum
                $   local
                ^.. traverse
                .   portSize
    let combine = config ^. configProperty . propCombine
    let clock   = Port Wire False 1 "clk"
    let yport =
            if combine then Port Wire False 1 "y" else Port Wire False size "y"
    let comb = combineAssigns_ combine yport local
    return
        . declareMod local
        . ModDecl name [yport] (clock : newPorts) (comb : mi)
        $ ps

-- | Procedural generation method for random Verilog. Uses internal 'Reader' and
-- 'State' to keep track of the current Verilog code structure.
procedural :: T.Text -> Config -> Gen Verilog
procedural top config = do
    (mainMod, st) <- Hog.resize num $ runReaderT
        (runStateT (moduleDef (Just $ Identifier top)) context)
        config
    return . Verilog $ mainMod : st ^. modules
  where
    context =
        Context [] [] [] 0 (confProp propStmntDepth) (confProp propModDepth) True
    num = fromIntegral $ confProp propSize
    confProp i = config ^. configProperty . i

-- | Samples the 'Gen' directly to generate random 'Verilog' using the 'T.Text' as
-- the name of the main module and the configuration 'Config' to influence the
-- generation.
proceduralIO :: T.Text -> Config -> IO Verilog
proceduralIO t = Hog.sample . procedural t

-- | Given a 'T.Text' and a 'Config' will generate a 'SourceInfo' which has the
-- top module set to the right name.
proceduralSrc :: T.Text -> Config -> Gen SourceInfo
proceduralSrc t c = SourceInfo t <$> procedural t c

-- | Sampled and wrapped into a 'SourceInfo' with the given top module name.
proceduralSrcIO :: T.Text -> Config -> IO SourceInfo
proceduralSrcIO t c = SourceInfo t <$> proceduralIO t c