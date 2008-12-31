{-  Author: Florian Haftmann, TU Muenchen

Reader for adaption table as generated by lib/mk_adapt.ML
-}

module ReadAdapt (readAdapt, Adaption(..)) where

import Control.Monad.Error (liftIO)

import qualified Language.Haskell.Exts as Hsx

import Importer.Utilities.Misc
import qualified Importer.Adapt.Common as Adapt
import qualified Importer.Msg as Msg


{- Adaption data -}

data Adaption = Adaption {
  raw_adaption_table :: [(Adapt.AdaptionEntry, Adapt.AdaptionEntry)],
  reserved_keywords :: [String],
  used_const_names :: [String],
  used_thy_names :: [String]
} deriving Show


{- File access -}

readError :: forall a. FilePath -> String -> a
readError file msg =
  error ("An error occurred while reading adaption file \"" ++ file ++ "\": " ++ msg)

parseAdapt :: FilePath -> IO [Hsx.Decl]
parseAdapt file = do
  result <- Hsx.parseFile file
    `catch` (\ ioError -> readError file (show ioError))
  case result of
    Hsx.ParseFailed loc msg ->
      readError file (Msg.failed_parsing loc msg)
    Hsx.ParseOk (Hsx.Module _ _ _ _ _ _ decls) ->
      return decls


{- Processing adaption declarations -}

indexify :: [Hsx.Decl] -> [(String, Hsx.Exp)]
indexify decls = fold idxify decls [] where
{-  idxify (Hsx.FunBind
    [Hsx.Match _ (Hsx.Ident name) _ (Hsx.UnGuardedRhs rhs) _]) xs =
      (name, rhs) : xs-}
  idxify (Hsx.PatBind _ (Hsx.PVar (Hsx.Ident name)) (Hsx.UnGuardedRhs rhs) _) xs =
      (name, rhs) : xs
  idxify _ xs = xs

evaluateString :: Hsx.Exp -> String
evaluateString (Hsx.Lit (Hsx.String s)) = s

evaluateList :: (Hsx.Exp -> a) -> Hsx.Exp -> [a]
evaluateList eval (Hsx.List ts) = map eval ts

evaluatePair :: (Hsx.Exp -> a) -> (Hsx.Exp -> b) -> Hsx.Exp -> (a, b)
evaluatePair eval1 eval2 (Hsx.Tuple [t1, t2]) = (eval1 t1, eval2 t2)

evaluateEntryClass :: Hsx.Exp -> Adapt.RawClassInfo
evaluateEntryClass (Hsx.Paren (Hsx.RecConstr (Hsx.UnQual (Hsx.Ident "RawClassInfo"))
  [Hsx.FieldUpdate (Hsx.UnQual (Hsx.Ident "superclasses")) superclasses,
    Hsx.FieldUpdate (Hsx.UnQual (Hsx.Ident "classVar")) classVar,
      Hsx.FieldUpdate (Hsx.UnQual (Hsx.Ident "methods")) methods])) =
  Adapt.RawClassInfo {
    Adapt.superclasses = evaluateList evaluateString superclasses,
    Adapt.classVar = evaluateString classVar,
    Adapt.methods = evaluateList (evaluatePair evaluateString evaluateString) methods }

evaluateEntryKind :: Hsx.Exp -> Adapt.OpKind
evaluateEntryKind (Hsx.Paren (Hsx.App (Hsx.Con (Hsx.UnQual (Hsx.Ident "Class"))) cls)) =
  Adapt.Class (evaluateEntryClass cls)
evaluateEntryKind (Hsx.Con (Hsx.UnQual (Hsx.Ident "Type"))) = Adapt.Type
evaluateEntryKind (Hsx.Con (Hsx.UnQual (Hsx.Ident "Function"))) = Adapt.Type
evaluateEntryKind (Hsx.Paren (Hsx.App (Hsx.App (Hsx.Con (Hsx.UnQual (Hsx.Ident "InfixOp")))
  (Hsx.Con (Hsx.UnQual (Hsx.Ident assc)))) (Hsx.Lit (Hsx.Int pri)))) =
    Adapt.InfixOp assoc (fromInteger pri) where
    assoc = case assc of
      "LeftAssoc" -> Adapt.LeftAssoc
      "RightAssoc" -> Adapt.RightAssoc
      "NoneAssoc" -> Adapt.NoneAssoc

evaluateEntry :: Hsx.Exp -> Adapt.AdaptionEntry
evaluateEntry (Hsx.App (Hsx.App (Hsx.Con (Hsx.UnQual (Hsx.Ident kind))) (Hsx.Lit (Hsx.String name))) entry)
  | (kind == "Haskell") = Adapt.Haskell name (evaluateEntryKind entry)
  | (kind == "Isabelle") = Adapt.Isabelle name (evaluateEntryKind entry)

evaluate decls = Adaption {
  raw_adaption_table = evaluateList (evaluatePair evaluateEntry evaluateEntry)
    (lookupFunbind "raw_adaption_table"),
  reserved_keywords = lookupStringList "reserved_keywords",
  used_const_names = lookupStringList "used_const_names",
  used_thy_names = lookupStringList "used_thy_names" } where
    lookupFunbind name = case lookup name decls of
      Nothing -> error ("No entry for " ++ name ++ " in adaption file")
      Just rhs -> rhs
    lookupStringList name = evaluateList evaluateString (lookupFunbind name)


{- Interface -}

readAdapt :: FilePath -> IO Adaption
readAdapt file = do
  decls <- parseAdapt file
  return (evaluate (indexify decls))
