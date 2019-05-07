{-|
Module      : VeriFuzz.Sim.Vivado
Description : Vivado Synthesiser implementation.
Copyright   : (c) 2019, Yann Herklotz Grave
License     : GPL-3
Maintainer  : ymherklotz [at] gmail [dot] com
Stability   : experimental
Portability : POSIX

Vivado Synthesiser implementation.
-}

module VeriFuzz.Sim.Vivado
    ( Vivado(..)
    , defaultVivado
    )
where

import           Data.Text                (Text, unpack)
import           Prelude                  hiding (FilePath)
import           Shelly
import           Shelly.Lifted            (liftSh)
import           VeriFuzz.Sim.Internal
import           VeriFuzz.Sim.Template
import           VeriFuzz.Verilog.AST
import           VeriFuzz.Verilog.CodeGen

data Vivado = Vivado { vivadoBin    :: !(Maybe FilePath)
                     , vivadoDesc   :: {-# UNPACK #-} !Text
                     , vivadoOutput :: {-# UNPACK #-} !FilePath
                     }
               deriving (Eq)

instance Tool Vivado where
    toText (Vivado _ t _) = t

instance Show Vivado where
    show t = unpack $ toText t

instance Synthesiser Vivado where
    runSynth = runSynthVivado
    synthOutput = vivadoOutput
    setSynthOutput (Vivado a b _) = Vivado a b

defaultVivado :: Vivado
defaultVivado = Vivado Nothing "vivado" "syn_vivado.v"

runSynthVivado :: Vivado -> SourceInfo -> ResultSh ()
runSynthVivado sim (SourceInfo top src) = do
    dir <- liftSh pwd
    liftSh $ do
        writefile vivadoTcl . vivadoSynthConfig top . toTextIgnore $ synthOutput
            sim
        writefile "rtl.v" $ genSource src
        run_ "sed" ["s/^module/(* use_dsp=\"no\" *) module/;", "-i", "rtl.v"]
        logger "Vivado: run"
    let exec_ n = execute_
            SynthFail
            dir
            "vivado"
            (maybe (fromText n) (</> fromText n) $ vivadoBin sim)
    exec_ "vivado" ["-mode", "batch", "-source", toTextIgnore vivadoTcl]
    liftSh $ logger "Vivado: done"
    where vivadoTcl = fromText ("vivado_" <> top) <.> "tcl"
