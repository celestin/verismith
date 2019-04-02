{-|
Module      : VeriFuzz
Description : VeriFuzz
Copyright   : (c) 2018-2019, Yann Herklotz
License     : BSD-3
Maintainer  : ymherklotz [at] gmail [dot] com
Stability   : experimental
Portability : POSIX
-}

module VeriFuzz
    ( runEquivalence
    , runSimulation
    , runReduce
    , draw
    , SourceInfo(..)
    , module VeriFuzz.AST
    , module VeriFuzz.Config
    , module VeriFuzz.ASTGen
    , module VeriFuzz.Circuit
    , module VeriFuzz.CodeGen
    , module VeriFuzz.Env
    , module VeriFuzz.Gen
    , module VeriFuzz.Icarus
    , module VeriFuzz.Mutate
    , module VeriFuzz.Parser
    , module VeriFuzz.Random
    , module VeriFuzz.Reduce
    , module VeriFuzz.XST
    , module VeriFuzz.Yosys
    )
where

import           Control.Lens
import qualified Crypto.Random.DRBG       as C
import           Data.ByteString          (ByteString)
import           Data.ByteString.Builder  (byteStringHex, toLazyByteString)
import qualified Data.ByteString.Lazy     as L
import qualified Data.Graph.Inductive     as G
import qualified Data.Graph.Inductive.Dot as G
import           Data.Text                (Text)
import qualified Data.Text                as T
import           Data.Text.Encoding       (decodeUtf8)
import qualified Data.Text.IO             as T
import           Hedgehog                 (Gen)
import qualified Hedgehog.Gen             as Hog
import           Prelude                  hiding (FilePath)
import           Shelly
import           VeriFuzz.AST
import           VeriFuzz.ASTGen
import           VeriFuzz.Circuit
import           VeriFuzz.CodeGen
import           VeriFuzz.Config
import           VeriFuzz.Env
import           VeriFuzz.Gen
import           VeriFuzz.Icarus
import           VeriFuzz.Internal
import           VeriFuzz.Mutate
import           VeriFuzz.Parser
import           VeriFuzz.Random
import           VeriFuzz.Reduce
import           VeriFuzz.XST
import           VeriFuzz.Yosys

-- | Generate a specific number of random bytestrings of size 256.
randomByteString :: C.CtrDRBG -> Int -> [ByteString] -> [ByteString]
randomByteString gen n bytes
    | n == 0    = ranBytes : bytes
    | otherwise = randomByteString newGen (n - 1) $ ranBytes : bytes
    where Right (ranBytes, newGen) = C.genBytes 32 gen

-- | generates the specific number of bytestring with a random seed.
generateByteString :: Int -> IO [ByteString]
generateByteString n = do
    gen <- C.newGenIO :: IO C.CtrDRBG
    return $ randomByteString gen n []

makeSrcInfo :: ModDecl -> SourceInfo
makeSrcInfo m =
    SourceInfo (m ^. modId . getIdentifier) (VerilogSrc [Description m])

-- | Draw a randomly generated DAG to a dot file and compile it to a png so it
-- can be seen.
draw :: IO ()
draw = do
    gr <- Hog.sample $ rDups . getCircuit <$> Hog.resize 10 randomDAG
    let dot = G.showDot . G.fglToDotString $ G.nemap show (const "") gr
    writeFile "file.dot" dot
    shelly $ run_ "dot" ["-Tpng", "-o", "file.png", "file.dot"]

-- | Function to show a bytestring in a hex format.
showBS :: ByteString -> Text
showBS = decodeUtf8 . L.toStrict . toLazyByteString . byteStringHex

-- | Run a simulation on a random DAG or a random module.
runSimulation :: IO ()
runSimulation = do
  -- gr <- Hog.generate $ rDups <$> Hog.resize 100 (randomDAG :: Gen (G.Gr Gate ()))
  -- let dot = G.showDot . G.fglToDotString $ G.nemap show (const "") gr
  -- writeFile "file.dot" dot
  -- shelly $ run_ "dot" ["-Tpng", "-o", "file.png", "file.dot"]
  -- let circ =
  --       head $ (nestUpTo 30 . generateAST $ Circuit gr) ^.. getVerilogSrc . traverse . getDescription
    rand  <- generateByteString 20
    rand2 <- Hog.sample (randomMod 10 100)
    val   <- shelly $ runSim defaultIcarus (makeSrcInfo rand2) rand
    T.putStrLn $ showBS val


-- | Code to be executed on a failure. Also checks if the failure was a timeout,
-- as the timeout command will return the 124 error code if that was the
-- case. In that case, the error will be moved to a different directory.
onFailure :: Text -> RunFailed -> Sh ()
onFailure t _ = do
    ex <- lastExitCode
    case ex of
        124 -> do
            echoP "Test TIMEOUT"
            chdir ".." $ cp_r (fromText t) $ fromText (t <> "_timeout")
        _ -> do
            echoP "Test FAIL"
            chdir ".." $ cp_r (fromText t) $ fromText (t <> "_failed")

checkEquivalence :: SourceInfo -> Text -> IO Bool
checkEquivalence src dir = shellyFailDir $ do
    mkdir_p (fromText dir)
    curr <- toTextIgnore <$> pwd
    setenv "VERIFUZZ_ROOT" curr
    cd (fromText dir)
    catch_sh
        (runEquiv defaultYosys defaultYosys (Just defaultXst) src >> return True
        )
        ((\_ -> return False) :: RunFailed -> Sh Bool)

-- | Run a fuzz run and check if all of the simulators passed by checking if the
-- generated Verilog files are equivalent.
runEquivalence :: Gen ModDecl -> Text -> Int -> IO ()
runEquivalence gm t i = do
    m <- Hog.sample gm
    let srcInfo = makeSrcInfo m
    rand <- generateByteString 20
    shellyFailDir $ do
        mkdir_p (fromText "output" </> fromText n)
        curr <- toTextIgnore <$> pwd
        setenv "VERIFUZZ_ROOT" curr
        cd (fromText "output" </> fromText n)
        catch_sh
                (  runEquiv defaultYosys defaultYosys (Just defaultXst) srcInfo
                >> echoP "Test OK"
                )
            $ onFailure n
        catch_sh
                (   runSim (Icarus "iverilog" "vvp") srcInfo rand
                >>= (\b -> echoP ("RTL Sim: " <> showBS b))
                )
            $ onFailure n
        cd ".."
        rm_rf $ fromText n
    when (i < 5) (runEquivalence gm t $ i + 1)
    where n = t <> "_" <> T.pack (show i)

runReduce :: SourceInfo -> IO SourceInfo
runReduce = reduce $ flip checkEquivalence "reduce"
