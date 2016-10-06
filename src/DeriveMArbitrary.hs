{-# LANGUAGE TemplateHaskell #-}

module DeriveMArbitrary where

import Control.Exception

import Language.Haskell.TH
import Language.Haskell.TH.Syntax

import Language.Haskell.GhcMod
import Language.Haskell.GhcMod.Browse

import Language.Haskell.Meta.Parse

-------------------------------------------------
--             Module crawler                  --
-------------------------------------------------
type Declaration = (Name, [TyVarBndr], Cxt, [Type])

opts = BrowseOpts { optBrowseOperators = True
                  , optBrowseDetailed  = True
                  , optBrowseQualified = True }

getModuleExports :: String -> IO ([Declaration], [String])
getModuleExports mod = do
    (res, log) <- handle (\e -> error (show (e :: SomeException))) $ runGhcModT defaultOptions $ browse opts mod
    case res of
        Left err  -> error $ "error browsing module: " ++ mod
        Right str -> return $ foldr parse ([],[]) $ lines str
                        
parse str (ok, failed) = 
    case parseExp str of
        Right (SigE (VarE name) ty) -> ((flattenDec name ty):ok, failed)
        _ -> (ok, str:failed)

flattenDec :: Name -> Type -> Declaration
flattenDec name (ForallT tvb cxt ty) = 
    let (_, tvb', cxt', ty') = flattenDec name ty
    in (name, tvb ++ tvb', cxt ++ cxt', ty')
flattenDec name (AppT (AppT ArrowT l) r) = 
    let (_, tvb', cxt', r') = flattenDec name r
    in (name, tvb', cxt', [l] ++ r')
flattenDec name t = (name, [], [], [t])


-------------------------------------------------
--  actions tree and perform code generation   --
-------------------------------------------------
devMArbitrary :: String -> Name -> Q [Dec]
devMArbitrary mod tname = do
    (decs, failed) <- runIO $ getModuleExports mod
    let actions = filter (\d -> resultType (toType tname) d && decidableArgs d) decs 
    adt <- devADT tname actions
    run <- devRun tname actions
    return [adt, run]


devADT :: Name -> [Declaration] -> DecQ
devADT tname funcs = dataD (cxt []) (mkTypeName tname) [] (map (devCon tname) funcs) [] 

devCon :: Name -> Declaration -> ConQ
devCon tname (n, tv, cxt, ty) = normalC (mkConName tname n) (map (devBangType tname) (init ty))

devBangType :: Name -> Type -> StrictTypeQ
devBangType tname t = strictType notStrict replaceFunction 
    where replaceFunction | toType tname `compat` t  = appT listT (conT $ mkTypeName tname)
                          | otherwise                = return t
                                    

devRun :: Name -> [Declaration] -> DecQ
devRun tname actions = funD (mkPerformName tname) $ emptyClause : (map (devClause tname) actions)

emptyClause = clause [listP []] (normalB [| return () |]) []

devClause :: Name -> Declaration -> ClauseQ
devClause tname (n,tvb,cxt,ts) =
    let cname = mkConName tname  n
        varsP = map (varP . mkVarName) [1..(length ts - 1)]  
        varsE = map (varE . mkVarName) [1..(length ts - 1)]
        actionP = conP cname varsP
        consMatch = infixP actionP (mkName ":") (varP $ mkVarMore tname)      
        consBody = (normalB (uInfixE (apply tname (n,tvb,cxt,init ts) varsE) 
                            (varE $ mkName ">>") 
                            (appE (varE $ mkPerformName tname) (varE $ mkVarMore tname))))
    in clause [consMatch] consBody []

    
apply :: Name -> Declaration -> [ExpQ] -> ExpQ
apply tname (n,_,_,_) [] = varE n 
apply tname (n,tvb,cxt,ts) vs = appE (apply tname (n,tvb,cxt,init ts) (init vs)) replaceAction 
    where replaceAction | toType tname `compat` last ts  = appE (varE (mkPerformName tname)) (last vs)
                        | otherwise                      = last vs
          


toType = ConT . mkName . nameBase 

mkTypeName n = mkName $ nameBase n ++ "Action"
mkConName tname n = mkName $ "Act_" ++ nameBase tname ++ "_" ++ nameBase n
mkPerformName n = mkName $ "perform" ++ nameBase n
mkVarName n = mkName $ "v" ++ show n
mkVarMore tname = mkName $ "more" ++ nameBase tname ++ "Actions"

resultType :: Type -> Declaration -> Bool
resultType rt (_,_,_,ty) = rt `compat` last ty

compat :: Type -> Type -> Bool
compat t (AppT l r)  = compat t l
compat (ConT c) (ConT c') =  c == c'  
compat _ _ = False

decidableArgs :: Declaration -> Bool
decidableArgs (_,_,_,ty) = all (not . hasVarT) ty

hasVarT :: Type -> Bool
hasVarT (VarT _) = True
hasVarT (AppT l r) = hasVarT l || hasVarT r
hasVarT (ConT _) = False
hasVarT _ = False


-------------------------------------------------
--                   Tests                     --
---------------------------------------------------
testParser :: String -> String -> IO ()
testParser mod ty  = do 
    (decs, failed) <- getModuleExports mod
    mapM_ print decs 
    putStrLn "----------------------------"
    let Right rt = parseType ty
    mapM_ print $ filter (resultType rt) decs
    putStrLn "----------------------------"
    mapM_ putStrLn failed

testDevAdt :: String -> String -> IO ()
testDevAdt mod ts = do
    (decs, failed) <- getModuleExports mod
    let tname = mkName ts
        Right rt = parseType ts
        rtdecs = filter (resultType rt) decs
        rtdecs' = filter decidableArgs rtdecs
    adt <- runQ $ devADT tname rtdecs'
    print $ ppr adt


testDevRun :: String -> String -> IO ()
testDevRun mod ts = do
    (decs, failed) <- getModuleExports mod
    let tname = mkName ts
        Right rt = parseType ts
        rtdecs = filter (resultType rt) decs
        rtdecs' = filter decidableArgs rtdecs
    run <- runQ $ devRun tname rtdecs'
    print $ ppr run
