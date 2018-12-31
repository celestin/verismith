{-|
Module      : Test.VeriFuzz.Verilog.Mutation
Description : Functions to mutate the Verilog AST.
Copyright   : (c) 2018-2019, Yann Herklotz Grave
License     : BSD-3
Maintainer  : ymherklotz [at] gmail [dot] com
Stability   : experimental
Portability : POSIX

Functions to mutate the Verilog AST from "Test.VeriFuzz.Verilog.AST" to generate
more random patterns, such as nesting wires instead of creating new ones.
-}

module Test.VeriFuzz.Verilog.Mutate where

import           Control.Lens
import           Data.Maybe                    (catMaybes, fromMaybe)
import           Test.VeriFuzz.Internal.Gen
import           Test.VeriFuzz.Internal.Shared
import           Test.VeriFuzz.Verilog.AST
import           Test.VeriFuzz.Verilog.CodeGen

-- $setup
-- >>> let mod = (ModDecl (Identifier "m") [Port (PortNet Wire) 5 (Identifier "y")] [Port (PortNet Wire) 5 "x"] [])
-- >>> let main = (ModDecl "main" [] [] [])

-- | Return if the 'Identifier' is in a 'ModDecl'.
inPort :: Identifier -> ModDecl -> Bool
inPort id mod = inInput
  where
    inInput = any (\a -> a ^. portName == id) $ mod ^. modInPorts ++ mod ^. modOutPorts

-- | Find the last assignment of a specific wire/reg to an expression, and
-- returns that expression.
findAssign :: Identifier -> [ModItem] -> Maybe Expression
findAssign id items =
  safe last . catMaybes $ isAssign <$> items
  where
    isAssign (ModCA (ContAssign val expr))
      | val == id = Just $ expr
      | otherwise = Nothing
    isAssign _ = Nothing

-- | Transforms an expression by replacing an Identifier with an
-- expression. This is used inside 'transformOf' and 'traverseExpr' to replace
-- the 'Identifier' recursively.
idTrans :: Identifier -> Expression -> Expression -> Expression
idTrans i expr (PrimExpr (PrimId id))
  | id == i = expr
  | otherwise = (PrimExpr (PrimId id))
idTrans _ _ e = e

-- | Replaces the identifier recursively in an expression.
replace :: Identifier -> Expression -> Expression -> Expression
replace = (transformOf traverseExpr .) . idTrans

-- | Nest expressions for a specific 'Identifier'. If the 'Identifier' is not found,
-- the AST is not changed.
--
-- This could be improved by instead of only using the last assignment to the
-- wire that one finds, to use the assignment to the wire before the current
-- expression. This would require a different approach though.
nestId :: Identifier -> ModDecl -> ModDecl
nestId id mod
  | not $ inPort id mod =
      let expr = fromMaybe def . findAssign id $ mod ^. moduleItems
      in mod & get %~ replace id expr
  | otherwise = mod
  where
    get = moduleItems . traverse . _ModCA . contAssignExpr
    def = PrimExpr $ PrimId id

-- | Replaces an identifier by a expression in all the module declaration.
nestSource :: Identifier -> VerilogSrc -> VerilogSrc
nestSource id src =
  src & getVerilogSrc . traverse . getDescription %~ nestId id

-- | Nest variables in the format @w[0-9]*@ up to a certain number.
nestUpTo :: Int -> VerilogSrc -> VerilogSrc
nestUpTo i src =
  foldl (flip nestSource) src $ Identifier . fromNode <$> [1..i]

-- | Add a Module Instantiation using 'ModInst' from the first module passed to
-- it to the body of the second module. It first has to make all the inputs into
-- @reg@.
--
-- >>> SrcShow $ instantiateMod mod main
-- module main;
-- wire [4:0] y;
-- reg [4:0] x;
-- endmodule
-- <BLANKLINE>
instantiateMod :: ModDecl -> ModDecl -> ModDecl
instantiateMod mod main =
  main & moduleItems %~ ((out ++ regIn)++)
  where
    out = Decl Nothing <$> mod ^. modOutPorts
    regIn = Decl Nothing <$> (mod ^. modInPorts & traverse . portType .~ Reg False)

-- | Initialise all the inputs and outputs to a module.
--
-- >>> SrcShow $ initMod mod
-- module m(y, x);
-- output wire [4:0] y;
-- input wire [4:0] x;
-- endmodule
-- <BLANKLINE>
initMod :: ModDecl -> ModDecl
initMod mod = mod & moduleItems %~ ((out ++ inp)++)
  where
    out = Decl (Just PortOut) <$> (mod ^. modOutPorts)
    inp = Decl (Just PortIn) <$> (mod ^. modInPorts)
