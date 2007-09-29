
module Importer.ConversionUnit 
    (ConversionUnit(..), makeConversionUnit) where

import IO
import Monad
import Data.Graph
import Data.Tree
import Language.Haskell.Hsx

import qualified Importer.IsaSyntax as Isa
import qualified Importer.Msg as Msg

import Importer.Utilities.Misc



data ConversionUnit = HsxUnit [HsModule]
                    | IsaUnit [Isa.Cmd]
  deriving (Show)


transitiveClosure :: HsModule -> IO [HsModule]
transitiveClosure hsmodule = grovelHsModules [] hsmodule

grovelHsModules :: [Module] -> HsModule -> IO [HsModule]
grovelHsModules visited hsmodule@(HsModule _loc modul _exports imports _decls) 
    = let imports' = filter ((`notElem` visited) . importModule) imports
          modules  = map importModule imports'
      in do hsmodules  <- mapM parseOrFail imports'
            hsmodules' <- concatMapM (grovelHsModules ([modul] ++ modules ++ visited)) hsmodules
            return (hsmodule : hsmodules')

parseOrFail (HsImportDecl { importLoc=importloc, importModule=(Module name) })
    = do result <- try (parseFile (name ++ ".hs"))
         case result of
           Left ioerror                -> fail (Msg.failed_import importloc name (show ioerror))
           Right (ParseFailed loc msg) -> fail (Msg.failed_import importloc name 
                                                       (Msg.failed_parsing loc msg))
           Right (ParseOk m)           -> return m

cyclesFromGraph :: Graph -> [[Vertex]]
cyclesFromGraph graph
    = filter ((>1) . length) $ map flatten (scc graph)


makeDependencyGraph hsmodule
    = do hsmodules <- transitiveClosure hsmodule
         return $ graphFromEdges (map makeEdge hsmodules)
    where makeEdge hsmodule@(HsModule _loc modul _exports imports _decls)
              = let imported_modules = map importModule imports
                in (hsmodule, modul, imported_modules)


makeConversionUnit hsmodule
    = do (depGraph, fromVertex, _) <- makeDependencyGraph hsmodule
         let cycles = cyclesFromGraph depGraph
         when (not (null cycles)) -- not a DAG?
              $ let toModuleName v = case fromVertex v of (_,Module n,_) -> n
                in fail (Msg.cycle_in_dependency_graph (map toModuleName (head cycles)))
         let toHsModule v = case fromVertex v of (m,_,_) -> m
         let [hsmodules]  = map (map toHsModule . flatten) (dff depGraph)
         return (HsxUnit hsmodules)

           