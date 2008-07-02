{-  ID:         $Id$
    Author:     Tobias C. Rittweiler, TU Muenchen
-}

module Importer.Preprocess (preprocessHsModule) where

import Maybe
import List
import Control.Monad.State
import Language.Haskell.Hsx

import Data.Generics.Biplate
import Data.Generics.Str

import Importer.Utilities.Misc -- (concatMapM, assert)
import Importer.Utilities.Hsk
import Importer.Utilities.Gensym

import qualified Importer.Msg as Msg
        
preprocessHsModule :: HsModule -> HsModule

preprocessHsModule (HsModule loc modul exports imports topdecls)
    = HsModule loc modul exports imports topdecls''
      where topdecls'  = runGensym 0 (runDelocalizer (concatMapM delocalize_HsDecl topdecls))
            topdecls'' = map normalizePatterns_HsDecl topdecls'



-- Delocalization of HsDecls:
--
--  Since Isabelle/HOL does not really support local function
--  declarations, we convert the Haskell AST to an equivalent AST
--  where every local function declaration is made a global
--  declaration. This includes where as well as let expressions.
--
--  Additionally, all variables defined in a where clause
--  are converted to an equivalent let expression.


-- We keep track of the names that are directly bound by a declaration,
-- as functions must not close over them. See below for an explanation.
type DelocalizerM a = StateT [HsQName] (State GensymCount) a

withBindings       :: [HsQName] -> DelocalizerM v -> DelocalizerM v
withBindings names m = do old <- getBindings; put (names ++ old); r <- m; put old; return r

getBindings :: DelocalizerM [HsQName]
getBindings = get

runDelocalizer :: DelocalizerM [HsDecl] -> State GensymCount [HsDecl]
runDelocalizer d = evalStateT d []

-- Main function. Takes a declaration, and returns a list of itself and all
-- priorly local declarations.
delocalize_HsDecl  :: HsDecl  -> DelocalizerM [HsDecl]

-- Helper functions. Return a properly alpha-converted version of their argument 
-- plus a list of globalized declarations.
delocalize_HsMatch :: HsMatch -> DelocalizerM (HsMatch, [HsDecl])
delocalize_HsRhs   :: HsRhs   -> DelocalizerM (HsRhs, [HsDecl])
delocalize_HsExp   :: HsExp   -> DelocalizerM (HsExp, [HsDecl])
delocalize_HsAlt   :: HsAlt   -> DelocalizerM (HsAlt, [HsDecl])

-- This additionally returns the renamings that reflect how the where-binds
-- were renamed. This is necessary, beacuse the body of the caller 
-- where these where-binds apply to, must also be alpha converted.
delocalize_HsBinds :: HsBinds -> DelocalizerM (HsBinds, [HsDecl], [Renaming])


delocalize_HsDecl (HsPatBind loc pat rhs wbinds)
    = withBindings (extractBindingNs pat)
      $ do (rhs', localdecls)  <- delocalize_HsRhs (letify wbinds rhs)
           return $ localdecls ++ [HsPatBind loc pat rhs' (HsBDecls [])]

delocalize_HsDecl (HsFunBind matchs)
    = do (matchs', localdecls) <- liftM (\(xs, ys) -> (xs, concat ys))
                                    $ mapAndUnzipM delocalize_HsMatch matchs
         return (localdecls ++ [HsFunBind matchs'])

delocalize_HsDecl decl  = assert (check decl) $ return [decl]
          -- Safety check to make sure we didn't miss anything.
    where check decl   = and [null (universeBi decl :: [HsBinds]),
                              null [ True | HsLet _ _ <- universeBi decl ]]
          isHsLet expr = case expr of HsLet _ _ -> True; _ -> False

delocalize_HsMatch (HsMatch loc name pats rhs wbinds)
    = withBindings (extractBindingNs pats)
      $ do (rhs', localdecls)  <- delocalize_HsRhs (letify wbinds rhs)
           return (HsMatch loc name pats rhs' (HsBDecls []), localdecls)

delocalize_HsBinds (HsBDecls localdecls)
    -- First rename the bindings that are established by LOCALDECLS to fresh identifiers,
    -- then also rename all occurences (i.e. recursive invocations) of these bindings
    -- within the body of the declarations.
    = do renamings    <- lift (freshIdentifiers (bindingsFromDecls localdecls))
         let localdecls' = map (renameFreeVars renamings . renameHsDecl renamings) localdecls
         localdecls'' <- concatMapM delocalize_HsDecl localdecls'
         closedVarNs  <- getBindings
         return (HsBDecls [], checkForClosures closedVarNs localdecls'', renamings)

delocalize_HsRhs (HsUnGuardedRhs exp)
    = do (exp', decls) <- delocalize_HsExp exp
         return (HsUnGuardedRhs exp', decls)

delocalize_HsAlt (HsAlt loc pat (HsUnGuardedAlt body) wbinds)
    = withBindings (extractBindingNs pat)
        $ do (body', localdecls) <- delocalize_HsExp (letify wbinds body)
             return (HsAlt loc pat (HsUnGuardedAlt body') (HsBDecls []), localdecls)

delocalize_HsExp (HsLet binds body)
    -- The let expression in Isabelle/HOL supports simple pattern matching. So we
    -- differentiate between pattern and other (e.g. function) bindings; the first
    -- ones are kept, the latter ones are converted to global bindings.
    = let (patBinds, otherBinds) = splitPatBinds binds
      in withBindings (extractBindingNs patBinds)
         $ do (otherBinds', decls, renamings) <- delocalize_HsBinds otherBinds
              (body', moredecls)              <- delocalize_HsExp (renameFreeVars renamings body)
              return (letify (renameFreeVars renamings patBinds) body', decls ++ moredecls)

delocalize_HsExp (HsCase body alternatives)
    = do (body', localdecls)    <- delocalize_HsExp body
         (alternatives', decls) <- liftM (\(xs, ys) -> (xs, concat ys))
                                      $ mapAndUnzipM delocalize_HsAlt alternatives
         return (HsCase body' alternatives', localdecls ++ decls)
    where

-- Base cases.
delocalize_HsExp e@(HsVar _) = return (e, [])
delocalize_HsExp e@(HsCon _) = return (e, [])
delocalize_HsExp e@(HsLit _) = return (e, [])
delocalize_HsExp (HsInfixApp e1 qop e2) 
    = do (e1', ds1) <- delocalize_HsExp e1
         (e2', ds2) <- delocalize_HsExp e2
         return (HsInfixApp e1' qop e2', ds1++ds2)
delocalize_HsExp (HsApp e1 e2)
    = do (e1', ds1) <- delocalize_HsExp e1
         (e2', ds2) <- delocalize_HsExp e2
         return (HsApp e1' e2', ds1++ds2)
delocalize_HsExp (HsLambda loc pats e)
    = do (e', ds) <- delocalize_HsExp e 
         return (HsLambda loc pats e', ds)
delocalize_HsExp (HsIf e1 e2 e3)
    = do (e1', ds1) <- delocalize_HsExp e1
         (e2', ds2) <- delocalize_HsExp e2
         (e3', ds3) <- delocalize_HsExp e3
         return (HsIf e1' e2' e3', ds1++ds2++ds3)
delocalize_HsExp (HsTuple es)
    = do (es', dss) <- mapAndUnzipM delocalize_HsExp es
         return (HsTuple es', concat dss)
delocalize_HsExp (HsList es)
    = do (es', dss) <- mapAndUnzipM delocalize_HsExp es
         return (HsList es', concat dss)
delocalize_HsExp (HsParen e)
    = do (e', ds) <- delocalize_HsExp e
         return (HsParen e', ds)

isHsPatBind (HsPatBind _ _ _ _) = True
isHsPatBind _ = False

-- Partitions HsBinds into (pattern bindings, other bindings).
splitPatBinds :: HsBinds -> (HsBinds, HsBinds)
splitPatBinds (HsBDecls decls) 
    = let (patDecls, typeSigs, otherDecls)    = unzip3 (map split decls)
          (patDecls', typeSigs', otherDecls') = (catMaybes patDecls, 
                                                 concatMap flattenHsTypeSig (catMaybes typeSigs), 
                                                 catMaybes otherDecls)
          (patTypeSigs, otherTypeSigs) 
              = partition (let patNs = concatMap (fromJust . namesFromHsDecl) patDecls'
                           in \sig -> head (fromJust (namesFromHsDecl sig)) `elem` patNs)
                          typeSigs'
      in (HsBDecls (patTypeSigs ++ patDecls'), HsBDecls (otherTypeSigs ++ otherDecls'))

    where split decl@(HsPatBind loc pat rhs binds)
              = (Just decl, Nothing, Nothing)
          split decl@(HsTypeSig loc names typ)
              = (Nothing, Just decl, Nothing)
          split decl = (Nothing, Nothing, Just decl)

flattenHsTypeSig :: HsDecl -> [HsDecl]
flattenHsTypeSig (HsTypeSig loc names typ)
    = map (\n -> HsTypeSig loc [n] typ) names


-- Closures over variables can obviously not be delocalized, as for instance
--
--    foo x = let bar y = y * x 
--            in bar 42
--
-- would otherwise be delocalized to the bogus
--
--    bar0 y = y * x
--
--    foo x  = bar0 42
--

checkForClosures :: [HsQName] -> [HsDecl] -> [HsDecl]
checkForClosures closedNs decls = map check decls
    where check decl = let loc:_  = childrenBi decl :: [SrcLoc]
                           freeNs = filter (flip isFreeVar decl) closedNs
                       in if (null freeNs) then decl 
                                           else error (Msg.free_vars_found loc freeNs)


-- Normalization of As-patterns

normalizePatterns_HsDecl :: HsDecl -> HsDecl

normalizePatterns_HsDecl (HsFunBind matchs)
    = HsFunBind (map normalizePatterns_HsMatch matchs)
    where
      normalizePatterns_HsMatch (HsMatch loc name pats (HsUnGuardedRhs body) where_binds)
          = let (pats', as_bindings) = unzip (map normalizePattern pats) in
            let body' = normalizePatterns_HsExp (makeCase loc (concat as_bindings) body)
            in HsMatch loc name pats' (HsUnGuardedRhs body') where_binds

normalizePatterns_HsDecl decl 
    = let (exps, regenerate) = (biplate' decl :: ([HsExp], [HsExp] -> HsDecl))
      in regenerate (map normalizePatterns_HsExp exps) 


biplate' thing
     = let (str, regen) = biplate thing in (flattenStr str, \xs -> regen (rebuildStr str xs))
    where flattenStr :: Str x -> [x]
          flattenStr Zero = []
          flattenStr (One x) = [x]
          flattenStr (Two strA strB) = flattenStr strA ++ flattenStr strB

          rebuildStr :: Str x -> [x] -> Str x
          rebuildStr str xs = let (str', []) = rebuild str xs in str'
              where rebuild Zero    xs     = (Zero, xs)
                    rebuild (One _) (x:xs) = (One x, xs)
                    rebuild (Two strA strB) xs
                        = let (strA', xs')  = rebuild strA xs
                              (strB', xs'') = rebuild strB xs'
                          in (Two strA' strB', xs'')
         

normalizePatterns_HsExp :: HsExp -> HsExp

normalizePatterns_HsExp (HsCase exp alts)
    = HsCase exp (map normalizePatterns_HsAlt alts)
    where
      normalizePatterns_HsAlt (HsAlt loc pat (HsUnGuardedAlt clause_body) where_binds)
          = let (pat', as_bindings) = normalizePattern pat in
            let clause_body'   = normalizePatterns_HsExp 
                                   $ if (null as_bindings) then clause_body
                                     else (makeCase loc as_bindings clause_body)
                 in HsAlt loc pat' (HsUnGuardedAlt clause_body') where_binds

normalizePatterns_HsExp (HsLambda loc pats body)
    = let (pats', as_bindings) = unzip (map normalizePattern pats) in
      let body' = normalizePatterns_HsExp (makeCase loc (concat as_bindings) body)
      in HsLambda loc pats' body'

normalizePatterns_HsExp e@(HsVar _) = e
normalizePatterns_HsExp e@(HsCon _) = e
normalizePatterns_HsExp e@(HsLit _) = e
normalizePatterns_HsExp (HsInfixApp e1 qop e2)
    = let e1' = normalizePatterns_HsExp e1
          e2' = normalizePatterns_HsExp e2
      in HsInfixApp e1' qop e2'
normalizePatterns_HsExp (HsApp e1 e2)
    = let e1' = normalizePatterns_HsExp e1
          e2' = normalizePatterns_HsExp e2
      in HsApp e1' e2'
normalizePatterns_HsExp (HsLet binds e) = HsLet binds (normalizePatterns_HsExp e)
normalizePatterns_HsExp (HsIf e1 e2 e3)
    = let e1' = normalizePatterns_HsExp e1
          e2' = normalizePatterns_HsExp e2
          e3' = normalizePatterns_HsExp e2
      in HsIf e1' e2' e3'
normalizePatterns_HsExp (HsTuple es) = HsTuple (map normalizePatterns_HsExp es)
normalizePatterns_HsExp (HsList es)  = HsList (map normalizePatterns_HsExp es)
normalizePatterns_HsExp (HsParen e)  = HsParen (normalizePatterns_HsExp e)



makeCase :: SrcLoc -> [(HsName, HsPat)] -> HsExp -> HsExp
makeCase _ [] body = body
makeCase loc bindings body
    = let (names, pats) = unzip bindings
      in HsCase (HsTuple (map (HsVar . UnQual) names))
           [HsAlt loc (HsPTuple pats) (HsUnGuardedAlt body) (HsBDecls [])]

normalizePattern :: HsPat -> (HsPat, [(HsName, HsPat)])

normalizePattern p@(HsPVar _)    = (p, [])
normalizePattern p@(HsPLit _)    = (p, [])
normalizePattern p@(HsPWildCard) = (p, [])
normalizePattern (HsPNeg p)      = let (p', as_pats) = normalizePattern p in (HsPNeg p', as_pats)
normalizePattern (HsPParen p)    = let (p', as_pats) = normalizePattern p in (HsPParen p', as_pats)

normalizePattern (HsPAsPat n pat) 
    = (HsPVar n, [(n, pat)])

normalizePattern (HsPTuple pats)  
    = let (pats', as_pats) = unzip (map normalizePattern pats)
      in (HsPTuple pats', concat as_pats)

normalizePattern (HsPList pats)
    = let (pats', as_pats) = unzip (map normalizePattern pats)
      in (HsPList pats', concat as_pats)

normalizePattern (HsPApp qn pats) 
    = let (pats', as_pats) = unzip (map normalizePattern pats)
      in (HsPApp qn pats', concat as_pats)

normalizePattern (HsPInfixApp p1 qn p2)
    = let (p1', as_pats1) = normalizePattern p1
          (p2', as_pats2) = normalizePattern p2
      in (HsPInfixApp p1' qn p2', concat [as_pats1, as_pats2])

normalizePattern p = error ("Pattern not supported: " ++ show p)