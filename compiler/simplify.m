%-----------------------------------------------------------------------------%
% Copyright (C) 1995 University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% Main author: zs.
%
% The two jobs of the simplification module are
%
%	to find and exploit opportunities for simplifying the internal form
%	of the program, both to optimize the code and to massage the code
%	into a form the code generator will accept, and
%
%	to warn the programmer about any constructs that are so simple that
%	they should not have been included in the program in the first place.

:- module simplify.

:- interface.

:- import_module hlds_pred, det_report.
:- import_module list, io.

:- pred simplify__proc(pred_id, proc_id, module_info,
	proc_info, proc_info, int, int, io__state, io__state).
:- mode simplify__proc(in, in, in, in, out, out, out, di, uo) is det.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module hlds_module, hlds_goal, hlds_data.
:- import_module det_report, det_util, det_analysis.
:- import_module globals, options, passes_aux.
:- import_module bool, set, map, require, std_util.

%-----------------------------------------------------------------------------%

simplify__proc(PredId, ProcId, ModuleInfo0, Proc0, Proc, WarnCnt, ErrCnt,
		State0, State) :-
	globals__io_get_globals(Globals, State0, State1),
	det_info_init(ModuleInfo0, PredId, ProcId, Globals, DetInfo),
	proc_info_goal(Proc0, Goal0),
	proc_info_get_initial_instmap(Proc0, ModuleInfo0, InstMap0),

	write_pred_progress_message("% Simplifying ", PredId,
		ModuleInfo0, State1, State2),
	simplify__goal(Goal0, InstMap0, DetInfo, Goal, Msgs),

	proc_info_set_goal(Proc0, Goal, Proc),
	det_report_msgs(Msgs, ModuleInfo0, WarnCnt, ErrCnt, State2, State).

%-----------------------------------------------------------------------------%

:- pred simplify__goal(hlds__goal, instmap, det_info,
	hlds__goal, list(det_msg)).
:- mode simplify__goal(in, in, in, out, out) is det.

simplify__goal(Goal0 - GoalInfo0, InstMap0, DetInfo, Goal - GoalInfo, Msgs) :-
	goal_info_get_determinism(GoalInfo0, Detism),
	(
		Detism = failure,
		det_info_get_fully_strict(DetInfo, no)
	->
		map__init(Empty),
		Goal = disj([], Empty),
		GoalInfo = GoalInfo0,		% need we massage this?
		Msgs = []
	;
		determinism_components(Detism, cannot_fail, MaxSoln),
		MaxSoln \= at_most_zero,
		det_info_get_fully_strict(DetInfo, no),
		goal_info_get_instmap_delta(GoalInfo0, DeltaInstMap),
		goal_info_get_nonlocals(GoalInfo0, NonLocalVars),
		no_output_vars(NonLocalVars, InstMap0, DeltaInstMap, DetInfo)
	->
		Goal = conj([]),
		GoalInfo = GoalInfo0,		% need we massage this?
		Msgs = []
	;
		simplify__goal_2(Goal0, GoalInfo0, InstMap0, DetInfo,
			Goal, Msgs),
		GoalInfo = GoalInfo0
	).

%-----------------------------------------------------------------------------%

:- pred simplify__goal_2(hlds__goal_expr, hlds__goal_info,
	instmap, det_info, hlds__goal_expr, list(det_msg)).
:- mode simplify__goal_2(in, in, in, in, out, out) is det.

simplify__goal_2(conj(Goals0), GoalInfo0, InstMap0, DetInfo, Goal, Msgs) :-
	( Goals0 = [SingleGoal0] ->
		% a singleton conjunction is equivalent to the goal itself
		simplify__goal(SingleGoal0, InstMap0, DetInfo, Goal - _, Msgs)
	;
		simplify__conj(Goals0, InstMap0, DetInfo, Goals1, Msgs),
		%
		% Conjunctions that cannot produce solutions may nevertheless
		% contain nondet and multidet goals. If this happens, the part
		% of the conjunction up to and including the always-failing
		% goal are put inside a some to appease the code generator.
		%
		goal_info_get_determinism(GoalInfo0, Detism),
		( determinism_components(Detism, CanFail, at_most_zero) ->
			simplify__fixup_nosoln_conj(Goals1, Goals, no, NeedCut),
			( NeedCut = yes ->
				determinism_components(InnerDetism,
					CanFail, at_most_many),
				goal_info_set_determinism(GoalInfo0,
					InnerDetism, InnerInfo),
				InnerGoal = conj(Goals) - InnerInfo,
				Goal = some([], InnerGoal)
			;
				Goal = conj(Goals)
			)
		;
			Goal = conj(Goals1)
		)
	).

simplify__goal_2(disj(Goals0, FV), _, InstMap0, DetInfo, Goal, Msgs) :-
	( Goals0 = [SingleGoal0] ->
		% a singleton disjunction is equivalent to the goal itself
		simplify__goal(SingleGoal0, InstMap0, DetInfo, Goal - _, Msgs)
	;
		simplify__disj(Goals0, InstMap0, DetInfo, Goals, Msgs),
		Goal = disj(Goals, FV)
	).

simplify__goal_2(switch(Var, SwitchCanFail, Cases0, FV), _, InstMap0, DetInfo,
		switch(Var, SwitchCanFail, Cases, FV), Msgs) :-
	simplify__switch(Cases0, InstMap0, DetInfo, Cases, Msgs).

simplify__goal_2(higher_order_call(A, B, C, D, E, F), _, _, _,
		 higher_order_call(A, B, C, D, E, F), []).

simplify__goal_2(call(PredId, B, C, D, E, F, G), GoalInfo, _, DetInfo,
		 call(PredId, B, C, D, E, F, G), Msgs) :-
	%
	% check for calls to predicates with `pragma obsolete' declarations
	%
	det_info_get_module_info(DetInfo, ModuleInfo),
	module_info_pred_info(ModuleInfo, PredId, PredInfo),
	pred_info_get_marker_list(PredInfo, Markers),
	( list__member(request(obsolete), Markers) ->
		Msgs = [warn_obsolete(PredId, GoalInfo)]
	;
		Msgs = []
	).

simplify__goal_2(unify(LT, RT0, M, U, C), _, InstMap0, DetInfo,
		 unify(LT, RT, M, U, C), Msgs) :-
	(
		RT0 = lambda_goal(PredOrFunc, Vars, Modes, LambdaDeclaredDet,
			Goal0)
	->
		simplify__goal(Goal0, InstMap0, DetInfo, Goal, Msgs),
		RT = lambda_goal(PredOrFunc, Vars, Modes, LambdaDeclaredDet,
			Goal)
	;
		RT = RT0,
		Msgs = []
	).

	% (A -> B ; C) is semantically equivalent to (A, B ; ~A, C).
	% If the deterministic of A means that one of these disjuncts
	% cannot succeed, then we replace the if-then-else with the
	% other disjunct. (We could also eliminate A, but we leave
	% that to the recursive invocations.)
	%
	% The conjunction operator in the remaining disjunct ought to be
	% a sequential conjunction, EXPLAIN WHY.
	%
	% However, currently reordering is only done in mode analysis,
	% not in the code generator, so we don't yet need a sequential
	% conjunction construct. This will change when constraint pushing
	% is finished, or when we start doing coroutining.

simplify__goal_2(if_then_else(Vars, Cond0, Then0, Else0, FV), GoalInfo0,
		InstMap0, DetInfo, Goal, Msgs) :-
	Cond0 = _ - CondInfo,
	goal_info_get_determinism(CondInfo, CondDetism),
	determinism_components(CondDetism, CondCanFail, CondSolns),
	( CondCanFail = cannot_fail ->
		goal_to_conj_list(Cond0, CondList),
		goal_to_conj_list(Then0, ThenList),
		list__append(CondList, ThenList, List),
		simplify__goal(conj(List) - GoalInfo0, InstMap0, DetInfo,
			Goal - _, Msgs1),
		Msgs = [ite_cond_cannot_fail(GoalInfo0) | Msgs1]
	; CondSolns = at_most_zero ->
		% Optimize away the condition and the `then' part.
		goal_to_conj_list(Else0, ElseList),
		List = [not(Cond0) - CondInfo | ElseList],
		simplify__goal(conj(List) - GoalInfo0, InstMap0, DetInfo,
			Goal - _, Msgs1),
		Msgs = [ite_cond_cannot_succeed(GoalInfo0) | Msgs1]
	; Else0 = disj([], _) - _ ->
		% (A -> C ; fail) is equivalent to (A, C)
		goal_to_conj_list(Cond0, CondList),
		goal_to_conj_list(Then0, ThenList),
		list__append(CondList, ThenList, List),
		simplify__goal(conj(List) - GoalInfo0, InstMap0, DetInfo,
			Goal - _, Msgs)
	;
		update_instmap(Cond0, InstMap0, InstMap1),
		simplify__goal(Cond0, InstMap0, DetInfo, Cond, CondMsgs),
		simplify__goal(Then0, InstMap1, DetInfo, Then, ThenMsgs),
		simplify__goal(Else0, InstMap0, DetInfo, Else, ElseMsgs),
		list__append(ThenMsgs, ElseMsgs, AfterMsgs),
		list__append(CondMsgs, AfterMsgs, Msgs),
		Goal = if_then_else(Vars, Cond, Then, Else, FV)
	).

simplify__goal_2(not(Goal0), GoalInfo0, InstMap0, DetInfo, Goal, Msgs) :-
	simplify__goal(Goal0, InstMap0, DetInfo, Goal1, Msgs1),
	(
		% replace `not true' with `fail'
		Goal1 = conj([]) - _GoalInfo
	->
		map__init(Empty),
		Goal = disj([], Empty),
		Msgs = [negated_goal_cannot_fail(GoalInfo0) | Msgs1]
	;
		% replace `not fail' with `true'
		Goal1 = disj([], _) - _GoalInfo2
	->
		Goal = conj([]),
		Msgs = [negated_goal_cannot_succeed(GoalInfo0) | Msgs1]
	;
		Goal = not(Goal1),
		Msgs = Msgs1
	).

simplify__goal_2(some(Vars1, Goal1), SomeInfo, InstMap0, DetInfo,
		Goal, Msgs) :-
	(
		Goal1 = some(Vars2, Goal2) - _GoalInfo1
	->
		% replace nested `some's with a single `some',
		list__append(Vars1, Vars2, Vars),
		Replacement = some(Vars, Goal2) - SomeInfo,
		simplify__goal(Replacement, InstMap0, DetInfo, Goal - _, Msgs)
	;
		Goal1 = disj(Disjuncts, FV) - DisjInfo,
		Disjuncts \= [],
		goal_info_get_determinism(SomeInfo, SomeDetism),
		determinism_components(SomeDetism, _SomeCanFail, SomeMaxSoln),
		SomeMaxSoln \= at_most_many,
		goal_info_get_determinism(DisjInfo, DisjDetism),
		determinism_components(DisjDetism, _DisjCanFail, DisjMaxSoln),
		DisjMaxSoln = at_most_many
	->
		(
			goal_info_get_instmap_delta(SomeInfo, DeltaInstMap),
			goal_info_get_nonlocals(SomeInfo, NonLocalVars),
			no_output_vars(NonLocalVars, InstMap0, DeltaInstMap,
				DetInfo)
		->
			OutputVars = no
		;
			OutputVars = yes
		),
		simplify__fixup_disj(Disjuncts, DisjDetism, OutputVars,
			DisjInfo, FV, InstMap0, DetInfo, FixedGoal, [], MsgsA),
		simplify__goal(FixedGoal - SomeInfo, InstMap0, DetInfo,
			Goal - _, MsgsB),
		list__append(MsgsA, MsgsB, Msgs)
	;
		simplify__goal(Goal1, InstMap0, DetInfo, NewGoal, Msgs),
		Goal = some(Vars1, NewGoal)
	).

simplify__goal_2(pragma_c_code(A, B, C, D, E), _, _, _,
		 pragma_c_code(A, B, C, D, E), []).

%-----------------------------------------------------------------------------%

:- pred simplify__conj(list(hlds__goal), instmap, det_info, list(hlds__goal),
	list(det_msg)).
:- mode simplify__conj(in, in, in, out, out) is det.

simplify__conj([], _InstMap0, _DetInfo, [], []).
simplify__conj([Goal0 | Goals0], InstMap0, DetInfo, Goals, Msgs) :-
	( Goal0 = conj([]) - _ ->
		simplify__conj(Goals0, InstMap0, DetInfo, Goals, Msgs)
	;
		simplify__goal(Goal0, InstMap0, DetInfo, Goal, MsgsA),
		update_instmap(Goal0, InstMap0, InstMap1),
		simplify__conj(Goals0, InstMap1, DetInfo, Goals1, MsgsB),
		Goals = [Goal | Goals1],
		list__append(MsgsA, MsgsB, Msgs)
	).

:- pred simplify__disj(list(hlds__goal), instmap, det_info, list(hlds__goal),
	list(det_msg)).
:- mode simplify__disj(in, in, in, out, out) is det.

simplify__disj([], _InstMap0, _DetInfo, [], []).
simplify__disj([Goal0 | Goals0], InstMap0, DetInfo, [Goal | Goals], Msgs) :-
	simplify__goal(Goal0, InstMap0, DetInfo, Goal, MsgsA),
	simplify__disj(Goals0, InstMap0, DetInfo, Goals, MsgsB),
	list__append(MsgsA, MsgsB, MsgsC),
	(
		Goal = _ - GoalInfo,
		goal_info_get_determinism(GoalInfo, Detism),
		determinism_components(Detism, _, MaxSolns),
		MaxSolns = at_most_zero
	->
		Msgs = [zero_soln_disjunct(GoalInfo) | MsgsC]
	;
		Msgs = MsgsC
	).

:- pred simplify__switch(list(case), instmap, det_info, list(case),
	list(det_msg)).
:- mode simplify__switch(in, in, in, out, out) is det.

simplify__switch([], _InstMap0, _DetInfo, [], []).
simplify__switch([Case0 | Cases0], InstMap0, DetInfo, [Case | Cases], Msgs) :-
	% Technically, we should update the instmap to reflect the
	% knowledge that the var is bound to this particular constructor,
	% but we wouldn't use that information here anyway, so we don't bother.
	Case0 = case(ConsId, Goal0),
	simplify__goal(Goal0, InstMap0, DetInfo, Goal, MsgsA),
	Case = case(ConsId, Goal),
	simplify__switch(Cases0, InstMap0, DetInfo, Cases, MsgsB),
	list__append(MsgsA, MsgsB, Msgs).

%-----------------------------------------------------------------------------%

	% Disjunctions that cannot succeed more than once when viewed from the
	% outside generally need some fixing up, and/or some warnings to be
	% issued.
	%
	% For locally multidet disjunctions without output vars, which are det
	% from the outside, generate a warning, and then as an optimization
	% replace the whole disjunction with a disjunct that cannot fail.
	% 
	% For locally det disjunctions with or without output var(s),
	% (i.e. disjunctions in which the end of every disjunct except
	% one is unreachable) generate a warning, and then as an
	% optimization find the first disjunct which cannot fail and
	% replace the whole disjunction with that disjunct.
	%
	% For locally nondet disjunctions without output vars, which are
	% semidet from outside, we replace them with an if-then-else.
	% (Is there any good reason for this? Why not just leave them
	% as semidet disjunctions?)
	%
	% For locally semidet disjunctions with or without output var(s),
	% (i.e. disjunctions in which the end of every disjunct except
	% one is unreachable) 
	% leave
	% the disjunction as semidet; the code generator must handle such
	% semidet disjunctions by emitting code equivalent to an if-then-else
	% chain. If the disjunction has output vars, generate a warning.
	% 
	% For locally semidet disjunctions without output var(s), we should
	% pick whichever of approaches 3 and 4 generates smaller code.
	%
	% For disjunctions that cannot succeed, generate a warning.
	%
	% The second argument is the *internal* determinism of the disjunction.

:- pred simplify__fixup_disj(list(hlds__goal), determinism, bool,
	hlds__goal_info, follow_vars, instmap, det_info, hlds__goal_expr,
	list(det_msg), list(det_msg)).
:- mode simplify__fixup_disj(in, in, in, in, in, in, in, out, in, out) is det.

simplify__fixup_disj(Disjuncts, cc_multidet, OutputVars, GoalInfo, _, _, _,
		Goal, Msgs0, Msgs) :-
	( OutputVars = no ->
		Msgs = [multidet_disj(GoalInfo, Disjuncts) | Msgs0]
	;
		Msgs = Msgs0
	),
	% Same considerations apply to GoalInfos as for det disjunctions
	% below.
	det_pick_no_fail_disjunct(Disjuncts, Goal - _).
simplify__fixup_disj(Disjuncts, multidet, OutputVars, GoalInfo, _, _, _,
		Goal, Msgs0, Msgs) :-
	( OutputVars = no ->
		Msgs = [multidet_disj(GoalInfo, Disjuncts) | Msgs0]
	;
		Msgs = Msgs0
	),
	% Same considerations apply to GoalInfos as for det disjunctions
	% below.
	det_pick_no_fail_disjunct(Disjuncts, Goal - _).
simplify__fixup_disj(Disjuncts, cc_nondet, OutputVars, GoalInfo, FV,
		_InstMap, _DetInfo, Goal, Msgs0, Msgs) :-
	Msgs = Msgs0,
	( OutputVars = no ->
		det_disj_to_ite(Disjuncts, GoalInfo, FV, IfThenElse),
		IfThenElse = Goal - _
	;
		% This is the case of a nondet disjunction in a
		% single-solution context. We can't replace it with
		% an if-then-else, because the disjuncts may bind output
		% variables. We just leave it as a model_semi disjunction;
		% the code generator will generate similar code to what
		% it would for an if-then-else.
		Goal = disj(Disjuncts, FV)
	).
simplify__fixup_disj(Disjuncts, nondet, OutputVars, GoalInfo, FV,
		_InstMap, _DetInfo, Goal, Msgs0, Msgs) :-
	Msgs = Msgs0,
	( OutputVars = no ->
		det_disj_to_ite(Disjuncts, GoalInfo, FV, IfThenElse),
		IfThenElse = Goal - _
	;
		% This is the case of a nondet disjunction in a
		% single-solution context. We can't replace it with
		% an if-then-else, because the disjuncts may bind output
		% variables. We just leave it as a model_semi disjunction;
		% the code generator will generate similar code to what
		% it would for an if-then-else.
		Goal = disj(Disjuncts, FV)
	).
simplify__fixup_disj(Disjuncts, det, _OutputVars, GoalInfo, _, _, _, Goal,
		Msgs0, Msgs) :-
	% We are discarding the GoalInfo of the picked goal; we will
	% replace it with the GoalInfo inferred for the disjunction
	% as a whole. Although the disjunction may be det while the
	% picked disjunct is erroneous, this is OK, since erronoues
	% and det use the same code model. The replacement of the
	% GoalInfo is necessary to prevent spurious determinism
	% errors outside the disjunction.
	Msgs = [det_disj(GoalInfo, Disjuncts) | Msgs0],
	det_pick_no_fail_disjunct(Disjuncts, Goal - _).
simplify__fixup_disj(Disjuncts, semidet, OutputVars, GoalInfo, FV, _, _, Goal,
		Msgs0, Msgs) :-
	( OutputVars = yes ->
		Msgs = [semidet_disj(GoalInfo, Disjuncts) | Msgs0]
	;
		Msgs = Msgs0
	),
	Goal = disj(Disjuncts, FV).
simplify__fixup_disj(Disjuncts, erroneous, _OutputVars, GoalInfo, _, _, _, Goal,
		Msgs0, Msgs) :-
	% Same considerations apply to GoalInfos as for det disjunctions
	% above.
	Msgs = [zero_soln_disj(GoalInfo, Disjuncts) | Msgs0],
	det_pick_no_fail_disjunct(Disjuncts, Goal - _).
simplify__fixup_disj(Disjuncts, failure, _OutputVars, GoalInfo, FV, _, _, Goal,
		Msgs0, Msgs) :-
	Msgs = [zero_soln_disj(GoalInfo, Disjuncts) | Msgs0],
	Goal = disj(Disjuncts, FV).

:- pred det_pick_no_fail_disjunct(list(hlds__goal), hlds__goal).
:- mode det_pick_no_fail_disjunct(in, out) is det.

det_pick_no_fail_disjunct([], _) :-
	error("cannot find a disjunct that cannot fail").
det_pick_no_fail_disjunct([Goal0 | Goals0], Goal) :-
	Goal0 = _ - GoalInfo0,
	goal_info_get_determinism(GoalInfo0, Detism),
	determinism_components(Detism, CanFail, _),
	( CanFail = cannot_fail ->
		Goal = Goal0
	;
		det_pick_no_fail_disjunct(Goals0, Goal)
	).

:- pred det_disj_to_ite(list(hlds__goal), hlds__goal_info, follow_vars,
	hlds__goal).
:- mode det_disj_to_ite(in, in, in, out) is det.

	% det_disj_to_ite is used to transform disjunctions that occur
	% in prunable contexts into if-then-elses.
	% For example, it would transform
	%
	%	( Disjunct1
	%	; Disjunct2
	%	; Disjunct3
	%	)
	% into
	%	( Disjunct1 ->
	%		true
	%	; Disjunct2 ->
	%		true
	%	;
	%		Disjunct3
	%	).

% det_disj_to_ite([], GoalInfo, FV, disj([], FV) - GoalInfo).
det_disj_to_ite([], _GoalInfo, _FV, _) :-
	error("reached base case of det_disj_to_ite").
det_disj_to_ite([Disjunct | Disjuncts], GoalInfo, FV, Goal) :-
	( Disjuncts = [] ->
		Goal = Disjunct
	;
		Cond = Disjunct,
		Cond = _CondGoal - CondGoalInfo,

		goal_info_init(ThenGoalInfo0),
		map__init(InstMap1),
		goal_info_set_instmap_delta(ThenGoalInfo0, reachable(InstMap1),
			ThenGoalInfo1),
		goal_info_set_determinism(ThenGoalInfo1, det, ThenGoalInfo),
		Then = conj([]) - ThenGoalInfo,

		det_disj_to_ite(Disjuncts, GoalInfo, FV, Rest),
		Rest = _RestGoal - RestGoalInfo,

		goal_info_get_nonlocals(CondGoalInfo, CondNonLocals),
		goal_info_get_nonlocals(RestGoalInfo, RestNonLocals),
		set__union(CondNonLocals, RestNonLocals, NonLocals),
		goal_info_set_nonlocals(GoalInfo, NonLocals, NewGoalInfo0),

		goal_info_get_instmap_delta(GoalInfo, InstMapDelta0),
		(
			InstMapDelta0 = reachable(InstMap0),
			map__select(InstMap0, NonLocals, InstMap),
			InstMapDelta = reachable(InstMap)
		;
			InstMapDelta0 = unreachable,
			InstMapDelta = InstMapDelta0
		),
		goal_info_set_instmap_delta(NewGoalInfo0, InstMapDelta,
			NewGoalInfo1),

		goal_info_get_determinism(CondGoalInfo, CondDetism),
		goal_info_get_determinism(RestGoalInfo, RestDetism),
		determinism_components(CondDetism, CondCanFail, CondMaxSoln),
		determinism_components(RestDetism, RestCanFail, RestMaxSoln),
		det_disjunction_canfail(CondCanFail, RestCanFail, CanFail),
		det_disjunction_maxsoln(CondMaxSoln, RestMaxSoln, MaxSoln0),
		( MaxSoln0 = at_most_many ->
			MaxSoln = at_most_one
		;
			MaxSoln = MaxSoln0
		),
		determinism_components(Detism, CanFail, MaxSoln),
		goal_info_set_determinism(NewGoalInfo1, Detism, NewGoalInfo),

		Goal = if_then_else([], Cond, Then, Rest, FV) - NewGoalInfo
	).

%-----------------------------------------------------------------------------%

:- pred simplify__fixup_nosoln_conj(list(hlds__goal), list(hlds__goal),
	bool, bool).
:- mode simplify__fixup_nosoln_conj(in, out, in, out) is det.

simplify__fixup_nosoln_conj([], _, _, _) :-
	error("conjunction without solutions has no failing goal").
simplify__fixup_nosoln_conj([Goal0 | Goals0], Goals, NeedCut0, NeedCut) :-
	Goal0 = _ - GoalInfo0,
	goal_info_get_determinism(GoalInfo0, Detism0),
	determinism_components(Detism0, _, MaxSolns0),
	( MaxSolns0 = at_most_zero ->
		Goals = [Goal0],
		NeedCut = NeedCut0
	;
		( MaxSolns0 = at_most_many ->
			NeedCut1 = yes
		;
			NeedCut1 = NeedCut0
		),
		simplify__fixup_nosoln_conj(Goals0, Goals1, NeedCut1, NeedCut),
		Goals = [Goal0 | Goals1]
	).

%-----------------------------------------------------------------------------%
