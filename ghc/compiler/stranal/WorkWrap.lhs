%
% (c) The GRASP/AQUA Project, Glasgow University, 1993-1996
%
\section[WorkWrap]{Worker/wrapper-generating back-end of strictness analyser}

\begin{code}
#include "HsVersions.h"

module WorkWrap ( workersAndWrappers ) where

IMP_Ubiq(){-uitous-}
IMPORT_1_3(List(nub))

import CoreSyn
import CoreUnfold	( Unfolding, certainlySmallEnoughToInline, calcUnfoldingGuidance )
import CmdLineOpts	( opt_UnfoldingCreationThreshold )

import CoreUtils	( coreExprType )
import Id		( getInlinePragma, getIdStrictness, mkWorkerId,
			  addIdStrictness, addInlinePragma, 
			  GenId, SYN_IE(Id)
			)
import IdInfo		( noIdInfo, addUnfoldInfo,  
			  mkStrictnessInfo, addStrictnessInfo, StrictnessInfo(..)
			)
import SaLib
import UniqSupply	( returnUs, thenUs, mapUs, getUnique, SYN_IE(UniqSM) )
import WwLib
\end{code}

We take Core bindings whose binders have their strictness attached (by
the front-end of the strictness analyser), and we return some
``plain'' bindings which have been worker/wrapper-ified, meaning:
\begin{enumerate}
\item
Functions have been split into workers and wrappers where appropriate;
\item
Binders' @IdInfos@ have been updated to reflect the existence
of these workers/wrappers (this is where we get STRICTNESS pragma
info for exported values).
\end{enumerate}

\begin{code}
workersAndWrappers :: [CoreBinding] -> UniqSM [CoreBinding]

workersAndWrappers top_binds
  = mapUs (wwBind True{-top-level-}) top_binds `thenUs` \ top_binds2 ->
    let
	top_binds3 = map make_top_binding top_binds2
    in
    returnUs (concat top_binds3)
  where
    make_top_binding :: WwBinding -> [CoreBinding]

    make_top_binding (WwLet binds) = binds
\end{code}

%************************************************************************
%*									*
\subsection[wwBind-wwExpr]{@wwBind@ and @wwExpr@}
%*									*
%************************************************************************

@wwBind@ works on a binding, trying each \tr{(binder, expr)} pair in
turn.  Non-recursive case first, then recursive...

\begin{code}
wwBind	:: Bool			-- True <=> top-level binding
	-> CoreBinding
	-> UniqSM WwBinding	-- returns a WwBinding intermediate form;
				-- the caller will convert to Expr/Binding,
				-- as appropriate.

wwBind top_level (NonRec binder rhs)
  = wwExpr rhs			`thenUs` \ new_rhs ->
    tryWW binder new_rhs 	`thenUs` \ new_pairs ->
    returnUs (WwLet [NonRec b e | (b,e) <- new_pairs])
      -- Generated bindings must be non-recursive
      -- because the original binding was.

------------------------------

wwBind top_level (Rec pairs)
  = mapUs do_one pairs		`thenUs` \ new_pairs ->
    returnUs (WwLet [Rec (concat new_pairs)])
  where
    do_one (binder, rhs) = wwExpr rhs 	`thenUs` \ new_rhs ->
			   tryWW binder new_rhs
\end{code}

@wwExpr@ basically just walks the tree, looking for appropriate
annotations that can be used. Remember it is @wwBind@ that does the
matching by looking for strict arguments of the correct type.
@wwExpr@ is a version that just returns the ``Plain'' Tree.
???????????????? ToDo

\begin{code}
wwExpr :: CoreExpr -> UniqSM CoreExpr

wwExpr e@(Var _)    = returnUs e
wwExpr e@(Lit _)    = returnUs e
wwExpr e@(Con  _ _) = returnUs e
wwExpr e@(Prim _ _) = returnUs e

wwExpr (Lam binder expr)
  = wwExpr expr			`thenUs` \ new_expr ->
    returnUs (Lam binder new_expr)

wwExpr (App f a)
  = wwExpr f			`thenUs` \ new_f ->
    returnUs (App new_f a)

wwExpr (SCC cc expr)
  = wwExpr expr			`thenUs` \ new_expr ->
    returnUs (SCC cc new_expr)

wwExpr (Coerce c ty expr)
  = wwExpr expr			`thenUs` \ new_expr ->
    returnUs (Coerce c ty new_expr)

wwExpr (Let bind expr)
  = wwBind False{-not top-level-} bind	`thenUs` \ intermediate_bind ->
    wwExpr expr				`thenUs` \ new_expr ->
    returnUs (mash_ww_bind intermediate_bind new_expr)
  where
    mash_ww_bind (WwLet  binds)   body = mkCoLetsNoUnboxed binds body
    mash_ww_bind (WwCase case_fn) body = case_fn body

wwExpr (Case expr alts)
  = wwExpr expr				`thenUs` \ new_expr ->
    ww_alts alts			`thenUs` \ new_alts ->
    returnUs (Case new_expr new_alts)
  where
    ww_alts (AlgAlts alts deflt)
      = mapUs ww_alg_alt alts		`thenUs` \ new_alts ->
	ww_deflt deflt			`thenUs` \ new_deflt ->
	returnUs (AlgAlts new_alts new_deflt)

    ww_alts (PrimAlts alts deflt)
      = mapUs ww_prim_alt alts		`thenUs` \ new_alts ->
	ww_deflt deflt			`thenUs` \ new_deflt ->
	returnUs (PrimAlts new_alts new_deflt)

    ww_alg_alt (con, binders, rhs)
      =	wwExpr rhs			`thenUs` \ new_rhs ->
	returnUs (con, binders, new_rhs)

    ww_prim_alt (lit, rhs)
      = wwExpr rhs			`thenUs` \ new_rhs ->
	returnUs (lit, new_rhs)

    ww_deflt NoDefault
      = returnUs NoDefault

    ww_deflt (BindDefault binder rhs)
      = wwExpr rhs			`thenUs` \ new_rhs ->
	returnUs (BindDefault binder new_rhs)
\end{code}

%************************************************************************
%*									*
\subsection[tryWW]{@tryWW@: attempt a worker/wrapper pair}
%*									*
%************************************************************************

@tryWW@ just accumulates arguments, converts strictness info from the
front-end into the proper form, then calls @mkWwBodies@ to do
the business.

We have to BE CAREFUL that we don't worker-wrapperize an Id that has
already been w-w'd!  (You can end up with several liked-named Ids
bouncing around at the same time---absolute mischief.)  So the
criterion we use is: if an Id already has an unfolding (for whatever
reason), then we don't w-w it.

The only reason this is monadised is for the unique supply.

\begin{code}
tryWW	:: Id				-- The fn binder
	-> CoreExpr			-- The bound rhs; its innards
					--   are already ww'd
	-> UniqSM [(Id, CoreExpr)]	-- either *one* or *two* pairs;
					-- if one, then no worker (only
					-- the orig "wrapper" lives on);
					-- if two, then a worker and a
					-- wrapper.
tryWW fn_id rhs
  | (certainlySmallEnoughToInline $
     calcUnfoldingGuidance (getInlinePragma fn_id) 
			  opt_UnfoldingCreationThreshold
			  rhs
    )
	    -- No point in worker/wrappering something that is going to be
	    -- INLINEd wholesale anyway.  If the strictness analyser is run
	    -- twice, this test also prevents wrappers (which are INLINEd)
	    -- from being re-done.

  || not has_strictness_info
  || not (worthSplitting revised_wrap_args_info)
  = returnUs [ (fn_id, rhs) ]

  | otherwise		-- Do w/w split
  = let
	(uvars, tyvars, wrap_args, body) = collectBinders rhs
    in
    mkWwBodies tyvars wrap_args 
	       (coreExprType body)
	       revised_wrap_args_info		`thenUs` \ (wrap_fn, work_fn, work_demands) ->
    getUnique					`thenUs` \ work_uniq ->
    let
	work_rhs  = work_fn body
	work_id   = mkWorkerId work_uniq fn_id (coreExprType work_rhs) work_info
	work_info = noIdInfo `addStrictnessInfo` mkStrictnessInfo work_demands Nothing

	wrap_rhs = wrap_fn work_id
	ww_cons  = nub (get_ww_cons wrap_rhs)
	wrap_id  = addInlinePragma (fn_id `addIdStrictness`
				    mkStrictnessInfo revised_wrap_args_info (Just (work_id, ww_cons)))
		-- Add info to the wrapper:
		--	(a) we want to inline it everywhere
		-- 	(b) we want to pin on its revised stricteness info
		--	(c) we pin on its worker id and the list of constructors mentioned in the wrapper
    in
    returnUs ([(work_id, work_rhs), (wrap_id, wrap_rhs)])
	-- Worker first, because wrapper mentions it
  where
    strictness_info     = getIdStrictness fn_id
    has_strictness_info = case strictness_info of
				StrictnessInfo _ _ -> True
				other		   -> False

    wrap_args_info = case strictness_info of
			StrictnessInfo args_info _ -> args_info
    revised_wrap_args_info = setUnpackStrategy wrap_args_info

-- This rather crude function snaffles out the constructors needed to 
-- make the wrapper, so that we can stick them in the strictness info.
-- They're only needed if this thing gets exported.
get_ww_cons (Lam _ body)		       = get_ww_cons body
get_ww_cons (App fn _)  		       = get_ww_cons fn
get_ww_cons (Case _ (AlgAlts [(con,_,rhs)] _)) = con : get_ww_cons rhs
get_ww_cons other			       = []
\end{code}
