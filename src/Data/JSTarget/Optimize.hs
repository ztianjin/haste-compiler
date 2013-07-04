{-# LANGUAGE PatternGuards, TupleSections, DoAndIfThenElse #-}
-- | Optimizations over the JSTarget AST.
module Data.JSTarget.Optimize (
    optimizeFun, tryTernary, topLevelInline
  ) where
import Data.JSTarget.AST
import Data.JSTarget.Op
import Data.JSTarget.Traversal
import Control.Applicative
import Data.List (foldl')
import qualified Data.Map as M
import qualified Data.Set as S

-- TODO: tryTernary may inline calls that would otherwise be in tail position
--       which is something we'd really like to avoid.

optimizeFun :: Var -> AST Exp -> AST Exp
optimizeFun f (AST ast js) =
  flip runTravM js $ do
    shrinkCase ast
    >>= inlineReturns
    >>= inlineAssigns True

topLevelInline :: AST Stm -> AST Stm
topLevelInline (AST ast js) = runTravM (inlineAssigns False ast) js

-- | Attempt to turn two case branches into a ternary operator expression.
tryTernary :: AST Exp
           -> AST Exp
           -> (AST Stm -> AST Stm)
           -> [(AST Exp, AST Stm -> AST Stm)]
           -> Maybe (AST Exp)
tryTernary scrut retEx def [(m, alt)] =
    case runTravM opt allJumps of
      AST (Just ex) js -> Just (AST ex js)
      _                -> Nothing
  where
    def' = def $ Return <$> retEx
    alt' = alt $ Return <$> retEx
    AST _ allJumps = scrut >> m >> def' >> alt'
    opt = do
      -- Make sure the return expression is used somewhere, then cut away all
      -- useless assignments. If what's left is a single Return statement,
      -- we have a pure expression suitable for use with ?:.
      def'' <- inlineAssignsLocal $ astCode def'
      alt'' <- inlineAssignsLocal $ astCode alt'
      case (def'', alt'') of
        (Return el, Return th) ->
          return $ Just $ IfEx (BinOp Eq (astCode scrut) (astCode m)) th el
        _ ->
          return Nothing
tryTernary _ _ _ _ =
  Nothing

-- | How many times does an expression satisfying the given predicate occur in
--   an AST (including jumps)?
occurrences :: JSTrav ast
            => (ASTNode -> Bool)
            -> (ASTNode -> Bool)
            -> ast
            -> TravM Occs
occurrences tr p ast =
    foldJS trav count Never ast
  where
    trav n node = tr node && n < Lots -- Stop traversal if we're already >1.
    count n node | p node = pure $ n + Once
    count n _             = pure n

-- | Replace all occurrences of an expression, without entering shared code
--   paths. IO ordering is preserved even when entering lambdas thanks to
--   State# RealWorld.
replaceEx :: JSTrav ast => (ASTNode -> Bool) -> Exp -> Exp -> ast -> TravM ast
replaceEx trav old new =
  mapJS trav (\x -> if x == old then pure new else pure x) pure

-- | Inline assignments where the assignee is only ever used once.
--   Does not inline anything into a shared code path, as that would break
--   things horribly.
--   Ignores LhsExp assignments, since we only introduce those when we actually
--   care about the assignment side effect.
inlineAssigns :: JSTrav ast => Bool -> ast -> TravM ast
inlineAssigns blackholeOK ast = do
    inlinable <- gatherInlinable ast
    mapJS (const True) return (inl inlinable) ast
  where
    varOccurs lhs (Exp (Var lhs')) = lhs == lhs'
    varOccurs _ _                  = False
    inl m keep@(Assign (NewVar mayReorder lhs) ex next) = do
      occursRec <- occurrences (const True) (varOccurs lhs) ex
      if occursRec == Never
        then do
          occursLocal <- occurrences (not <$> isShared) (varOccurs lhs) next
          case M.lookup lhs m of
            Just occ | occ == occursLocal ->
              case occ of
                -- Never-used symbols don't need assignment.
                Never | blackholeOK -> do
                  return (Assign blackHole ex next)
                -- Inline of any non-lambda value
                Once | mayReorder -> do
                  replaceEx (not <$> isShared) (Var lhs) ex next
                -- Don't inline lambdas, but use less verbose syntax.
                _     | Fun Nothing vs body <- ex,
                        Internal lhsname _ <- lhs -> do
                  return $ Assign blackHole (Fun (Just lhsname) vs body) next
                _ -> do
                  return keep
            _ ->
              return keep
        else do
          return keep
    inl _ stm = return stm

-- | Gather a map of all inlinable symbols; that is, the once that are used
--   exactly once.
gatherInlinable :: JSTrav ast => ast -> TravM (M.Map Var Occs)
gatherInlinable =
    fmap (M.filter (< Lots)) . foldJS (\_ _ -> True) countOccs M.empty
  where
    updVar (Just occs) = Just (occs+Once)
    updVar _           = Just Once
    updVarAss (Just o) = Just o
    updVarAss _        = Just Never
    countOccs m (Exp (Var v@(Internal _ _))) =
      pure $ M.alter updVar v m
    countOccs m (Stm (Assign (NewVar _ v) _ _)) =
      pure $ M.alter updVarAss v m
    countOccs m _ =
      pure m

-- | Like `inlineAssigns`, but doesn't care what happens beyond a jump.
inlineAssignsLocal :: JSTrav ast => ast -> TravM ast
inlineAssignsLocal ast = do
    mapJS (\n -> not (isLambda n || isShared n)) return inl ast
  where
    varOccurs lhs (Exp (Var lhs')) = lhs == lhs'
    varOccurs _ _                  = False
    inl keep@(Assign (NewVar mayReorder lhs) ex next) = do
      occurs <- occurrences (const True) (varOccurs lhs) next
      occurs' <- occurrences (const True) (varOccurs lhs) ex
      case occurs + occurs' of
        Never ->
          return (Assign blackHole ex next)
        -- Don't inline lambdas at the moment, but use less verbose syntax.
        _     | Fun Nothing vs body <- ex,
                Internal lhsname _ <- lhs ->
          return $ Assign blackHole (Fun (Just lhsname) vs body) next
        Once | mayReorder ->
          -- can't be recursive - inline
          replaceEx (not <$> isShared) (Var lhs) ex next
        _ ->
          -- Really nothing to be done here.
          return keep
    inl stm = return stm

-- | Turn sequences like `v0 = foo; v1 = v0; v2 = v1; return v2;` into a
--   straightforward `return foo;`.
--   Ignores LhsExp assignments, since we only introduce those when we actually
--   care about the assignment side effect.
inlineReturns :: JSTrav ast => ast -> TravM ast
inlineReturns ast = do
    (s, ast') <- foldMapJS (\_ _ -> True) pure2 foldRet S.empty ast
    mapM_ (flip putRef NullRet) $ S.toList s
    return ast'
  where
    pure2 s x = pure (s,x)
    foldRet s (Assign (NewVar _ lhs) rhs (Return (Var v))) | v == lhs = do
      return (s, Return rhs)
    foldRet s keep@(Assign (NewVar _ lhs) rhs (Jump (Shared lbl))) = do
      next <- getRef lbl
      case next of
        Return (Var v) | v == lhs ->
          return (S.insert lbl s, Return rhs)
        _ ->
          return (s, keep)
    foldRet s keep = do
      return (s, keep)

-- | Inline all occurrences of the given shared code path.
--   Use with caution - preferrably not at all!
inlineShared :: JSTrav ast => Lbl -> ast -> TravM ast
inlineShared lbl =
    mapJS (const True) pure inl
  where
    inl (Jump (Shared lbl')) | lbl == lbl' = getRef lbl
    inl s                                  = pure s

-- | Shrink case statements as much as possible.
shrinkCase :: JSTrav ast => ast -> TravM ast
shrinkCase =
    mapJS (const True) pure shrink
  where
    shrink (Case _ def [] next@(Shared lbl))
      | def == Jump next = getRef lbl
      | otherwise        = inlineShared lbl def
    shrink stm           = return stm

-- | Turn tail recursion on the given var into a loop, if possible.
--   TODO: optimize tail recursive functions that create closures into:
--   function f(a', b', c') {
--     while(1) {
--       (function(a, b, c) {
--         a' = a; b' = b; c' = c;
--       })(a', b', c');
--     }
--   }
tailLoopify :: Var -> Exp -> TravM Exp
tailLoopify f fun@(Fun mname args body) = do
    tailrecs <- occurrences (not <$> isLambda) isTailRec body
    if tailrecs > Never
      then do
        needToCopy <- createsClosures body
        case needToCopy of
          True -> do
            return fun -- TODO: add optimization here as well!
          False -> do
            body' <- mapJS (not <$> isLambda) pure replaceByAssign body
            return $ Fun mname args (Forever body')
      else do
        return fun
  where
    isTailRec (Stm (Return (Call _ _ (Var f') _))) = f == f'
    isTailRec _                                    = False
    
    -- Only traverse until we find a closure
    createsClosures = foldJS (\acc _ -> not acc) isClosure False
    isClosure _ (Exp (Fun _ _ _)) = pure True
    isClosure acc _               = pure acc

    -- Assign any changed vars, then loop.
    replaceByAssign (Return (Call _ _ (Var f') args')) | f == f' = do
      return $ foldl' assignUnlessEqual Cont (zip args args')
    replaceByAssign stm =
      return stm

    -- Assign an expression to a variable, unless that expression happens to
    -- be the variable itself.
    assignUnlessEqual next (v, (Var v')) | v == v' =
      next
    assignUnlessEqual next (v, x) =
      Assign (LhsExp (Var v)) x next
tailLoopify _ fun = do
  return fun
