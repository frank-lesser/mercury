%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2010 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: query.m.
% Authors: pbone.
%
% This module contains code that analysis the recursive structures of cliques.
% It is intended for use on the automatic parallelisation analysis.
%
%----------------------------------------------------------------------------%

:- module recursion_patterns.
:- interface.

:- import_module report.
:- import_module profile.

:- import_module maybe.
            
%----------------------------------------------------------------------------%

:- pred create_clique_recursion_costs_report(deep::in, clique_ptr::in,
    maybe_error(clique_recursion_report)::out) is det.

:- pred create_recursion_types_frequency_report(deep::in, 
    maybe_error(recursion_types_frequency_report)::out) is det.

%----------------------------------------------------------------------------%
%----------------------------------------------------------------------------%

:- implementation.

:- import_module array_util.
:- import_module coverage.
:- import_module create_report.
:- import_module mdbcomp.
:- import_module mdbcomp.program_representation.
:- import_module measurement_units.
:- import_module measurements.
:- import_module program_representation_utils.
:- import_module report.

:- import_module array.
:- import_module assoc_list.
:- import_module float.
:- import_module int.
:- import_module io.
:- import_module list.
:- import_module map.
:- import_module pair.
:- import_module require.
:- import_module set.
:- import_module solutions.
:- import_module string.
:- import_module svmap.
:- import_module svset.
:- import_module unit.

%----------------------------------------------------------------------------%

create_clique_recursion_costs_report(Deep, CliquePtr,
        MaybeCliqueRecursionReport) :-
    find_clique_first_and_other_procs(Deep, CliquePtr, MaybeFirstPDPtr, 
        OtherPDPtrs),
    (
        MaybeFirstPDPtr = yes(FirstPDPtr),
        NumProcs = length(OtherPDPtrs) + 1,
        (
            OtherPDPtrs = [],
            % Exaclty one procedure
            proc_get_recursion_type(Deep, CliquePtr, FirstPDPtr, 
                MaybeRecursionType)
        ;
            OtherPDPtrs = [_ | _],
            % More than one, this is some sort of multiply recursion.
            MaybeRecursionType = ok(rt_mutual_recursion(NumProcs))
        ),
        (
            MaybeRecursionType = ok(RecursionType),
            CliqueRecursionReport = clique_recursion_report(CliquePtr,
                RecursionType, NumProcs),
            MaybeCliqueRecursionReport = ok(CliqueRecursionReport)
        ;
            MaybeRecursionType = error(Error),
            MaybeCliqueRecursionReport = error(Error)
        )
    ;
        MaybeFirstPDPtr = no,
        MaybeCliqueRecursionReport = error(
            "This clique doesn't appear to have an entry procedure")
    ).

:- pred proc_get_recursion_type(deep::in, clique_ptr::in, 
    proc_dynamic_ptr::in, maybe_error(recursion_type)::out) is det.

proc_get_recursion_type(Deep, ThisClique, PDPtr, MaybeRecursionType) :-
    lookup_pd_own(Deep ^ pd_own, PDPtr, PDOwn),
    Calls = calls(PDOwn),
    lookup_proc_dynamics(Deep ^ proc_dynamics, PDPtr, PD), 
    PSPtr = PD ^ pd_proc_static, 
    % TODO: Don't use coverage information here, it's computationally expensive
    % and shouldn't be necessary.  But more importantly it is per proc static
    % and therefore not suitable for calculating the depths of recursion.
    create_static_procrep_coverage_report(Deep, PSPtr, MaybeCoverageReport),
    (
        MaybeCoverageReport = ok(CoverageReport),
        ProcRep = CoverageReport ^ prci_proc_rep, 
        Goal = ProcRep ^ pr_defn ^ pdr_goal,
        array.foldl(build_call_site_cost_and_callee_map(Deep), 
        PD ^ pd_sites, map.init, CallSitesMap),
        goal_recursion_data(ThisClique, CallSitesMap, empty_goal_path,
            Goal, RecursionData),
        recursion_data_to_recursion_type(Calls, RecursionData,
            RecursionType),
        MaybeRecursionType = ok(RecursionType)
    ;
        MaybeCoverageReport = error(Error), 
        MaybeRecursionType = error(Error)
    ).

:- type cost_and_callees
    --->    cost_and_callees(
                cac_cost            :: int,
                cac_callees         :: set(clique_ptr)
            ).

:- pred build_call_site_cost_and_callee_map(deep::in, 
    call_site_array_slot::in,
    map(goal_path, cost_and_callees)::in, map(goal_path, cost_and_callees)::out)
    is det.

build_call_site_cost_and_callee_map(Deep, slot_normal(CSDPtr), !CallSitesMap)
        :-
    ( valid_call_site_dynamic_ptr(Deep, CSDPtr) ->
        call_site_dynamic_get_callee_and_costs(Deep, CSDPtr, CalleeCliquePtr, 
            Own, Inherit),
        % XXX: Should this be per call?
        Cost = callseqs(Own) + inherit_callseqs(Inherit),
        CostAndCallees = cost_and_callees(Cost, set([CalleeCliquePtr])),
        lookup_call_site_static_map(Deep ^ call_site_static_map, CSDPtr, CSSPtr),
        lookup_call_site_statics(Deep ^ call_site_statics, CSSPtr, CSS),
        goal_path_from_string_det(CSS ^ css_goal_path, GoalPath),
        svmap.det_insert(GoalPath, CostAndCallees, !CallSitesMap)
    ;
        true
    ).
build_call_site_cost_and_callee_map(Deep, slot_multi(_, CSDPtrsArray),
        !CallSitesMap) :-
    to_list(CSDPtrsArray, CSDPtrs),
    (
        CSDPtrs = []
        % There is no way of finding the goal path, so we can't put such a goal
        % in our map.  This probably can't happen in reality anyway.
    ;
        CSDPtrs = [FirstCSDPtr | _],

        map3(call_site_dynamic_get_callee_and_costs(Deep), CSDPtrs, 
            CalleeCliquePtrs, Owns, Inherits),
        Own = sum_own_infos(Owns),
        Inherit = sum_inherit_infos(Inherits),
        Cost = callseqs(Own) + inherit_callseqs(Inherit),
        CostAndCallees = cost_and_callees(Cost, set(CalleeCliquePtrs)),

        % The goal path of the call site will be the same regardless of the
        % callee, so we get it from the first.
        lookup_call_site_static_map(Deep ^ call_site_static_map, FirstCSDPtr,
            FirstCSSPtr),
        lookup_call_site_statics(Deep ^ call_site_statics, FirstCSSPtr,
            FirstCSS),
        goal_path_from_string_det(FirstCSS ^ css_goal_path, GoalPath),
        svmap.det_insert(GoalPath, CostAndCallees, !CallSitesMap)
    ).

:- pred call_site_dynamic_get_callee_and_costs(deep::in, 
    call_site_dynamic_ptr::in, clique_ptr::out, own_prof_info::out, 
    inherit_prof_info::out) is det.

call_site_dynamic_get_callee_and_costs(Deep, CSDPtr, CalleeCliquePtr, Own,
        Inherit) :-
    lookup_call_site_dynamics(Deep ^ call_site_dynamics, CSDPtr, CSD),
    lookup_csd_desc(Deep ^ csd_desc, CSDPtr, Inherit),
    PDPtr = CSD ^ csd_callee,
    lookup_clique_index(Deep ^ clique_index, PDPtr, CalleeCliquePtr), 
    Own = CSD ^ csd_own_prof.

:- pred recursion_data_to_recursion_type(int::in, recursion_data::in,
    recursion_type::out) is det.

recursion_data_to_recursion_type(CallsI, 
        recursion_data(Levels, Maximum, Errors), Type) :-
    Calls = float(CallsI),
    ( search(Levels, 0, RLBase) ->
        RLBase = recursion_level(BaseCost, BaseProb),
        BaseCount = round_to_int(probability_to_float(BaseProb) * Calls)
    ;
        BaseCost = 0.0,
        BaseCount = 0,
        BaseProb = impossible
    ),
    BaseLevel = recursion_level_report(0, BaseCount, BaseProb, BaseCost, 0.0), 
    ( empty(Errors) ->
        ( Maximum < 0 ->
            error(this_file ++ "negative number of recursive calls")
        ; Maximum = 0 ->
            Type = rt_not_recursive
        ; Maximum = 1 ->
            ( search(Levels, 1, RLRec) ->
                RLRec = recursion_level(RecCost, RecProb),
                RecCountF = probability_to_float(RecProb) * Calls,
                RecLevel = recursion_level_report(1, round_to_int(RecCountF),
                    RecProb, RecCost, RecCountF)
            ;
                error(format("%smaximum level %d not found", 
                    [s(this_file), i(1)]))
            ),
            Type = rt_single(BaseLevel, RecLevel)
        ;
            Maximum = 2,
            not search(Levels, 1, _)
        ->
            ( search(Levels, 2, RLRec) ->
                RLRec = recursion_level(RecCost, RecProb),
                RecCountF = probability_to_float(RecProb) * Calls,
                RecLevel = recursion_level_report(2, round_to_int(RecCountF),
                    RecProb, RecCost, RecCountF*2.0)
            ;
                error(format("%smaximum level %d not found", 
                    [s(this_file), i(1)]))
            ),
            Type = rt_divide_and_conquer(BaseLevel, RecLevel)
        ;
            map(recursion_level_report(Calls), Levels, LevelsReport),
            Type = rt_other(LevelsReport)
        )
    ;
        Messages = map(error_to_string, to_sorted_list(Errors)),
        Type = rt_errors(Messages)
    ).
% A procedure that is never called never recurses.
recursion_data_to_recursion_type(_, proc_dead_code, rt_not_recursive).

:- pred recursion_level_report(float::in, pair(int, recursion_level)::in, 
    recursion_level_report::out) is det.

recursion_level_report(TotalCalls, Level - recursion_level(NonRecCost, Prob), 
        recursion_level_report(Level, Calls, Prob, NonRecCost, CostExChild)) :-
    CallsF = probability_to_float(Prob) * TotalCalls,
    Calls = round_to_int(CallsF),
    CostExChild = float(Level) * CallsF.

%----------------------------------------------------------------------------%

:- type recursion_data
    --->    recursion_data(
                rd_recursions           :: assoc_list(int, recursion_level),
                rd_maximum              :: int,
                rd_errors               :: set(recursion_error)
            )
                
                % This code is dead, it is never entered.
    ;       proc_dead_code.

:- type recursion_level
    --->    recursion_level(
                rl_cost                 :: float,

                % The probability the path leading to this recursion level is
                % called given that the goal is called.
                rl_probability          :: probability
            ).

:- type recursion_error
    --->    re_unhandled_determinism(detism_rep)
    ;       re_unhandled_disjunction.

    % goal_recursion_data(RecursiveCallees, Goal, GoalPath,
    %   init_recursion_data, RecursionData)
    %
    % Compute RecursionData about Goal if RecursiveCalls are calls that may
    % eventually lead to Goal.
    %
:- pred goal_recursion_data(clique_ptr::in, 
    map(goal_path, cost_and_callees)::in, goal_path::in,
    goal_rep(coverage_info)::in, recursion_data::out) is det.

goal_recursion_data(ThisClique, CallSiteMap, GoalPath, GoalRep, 
        !:RecursionData) :-
    GoalRep = goal_rep(GoalExpr, Detism, CoverageInfo),
    ( get_coverage_before(CoverageInfo, CallsPrime) ->
        Calls = CallsPrime
    ;
        error(this_file ++ "couldn't retrive coverage information")
    ),
    ( Calls = 0 ->
        !:RecursionData = proc_dead_code
    ;
        (
            GoalExpr = conj_rep(Conjs),
            conj_recursion_data(ThisClique, CallSiteMap, GoalPath, 1, certain,
                Conjs, !:RecursionData)
        ;
            GoalExpr = disj_rep(Disjs),
            disj_recursion_data(ThisClique, CallSiteMap, GoalPath, 1, Disjs,
                !:RecursionData)
        ;
            GoalExpr = switch_rep(_, _, Cases),
            switch_recursion_data(ThisClique, CallSiteMap, GoalPath, 1, Cases,
                float(Calls), !:RecursionData)
        ;
            GoalExpr = ite_rep(Cond, Then, Else),
            ite_recursion_data(ThisClique, CallSiteMap, GoalPath, 
                Cond, Then, Else, Calls, !:RecursionData) 
        ;
            ( 
                GoalExpr = negation_rep(SubGoal),
                GoalPathStep = step_neg
            ; 
                GoalExpr = scope_rep(SubGoal, MaybeCut),
                GoalPathStep = step_scope(MaybeCut)
            ),
            goal_recursion_data(ThisClique, CallSiteMap,
                goal_path_add_at_end(GoalPath, GoalPathStep), SubGoal,
                !:RecursionData)
        ;
            GoalExpr = atomic_goal_rep(_, _, _, AtomicGoalRep),
            atomic_goal_recursion_data(ThisClique, CallSiteMap, GoalPath,
                AtomicGoalRep, !:RecursionData)
        )
    ),
    (
        ( Detism = det_rep
        ; Detism = semidet_rep
        ; Detism = cc_nondet_rep
        ; Detism = cc_multidet_rep
        ; Detism = erroneous_rep
        ; Detism = failure_rep
        )
    ;
        ( Detism = nondet_rep
        ; Detism = multidet_rep
        ),
        recursion_data_add_error(re_unhandled_determinism(Detism),
            !RecursionData)
    ).

:- pred conj_recursion_data(clique_ptr::in, 
    map(goal_path, cost_and_callees)::in, goal_path::in, int::in,
    probability::in, list(goal_rep(coverage_info))::in, recursion_data::out)
    is det.

    % An empty conjunction is true, there is exactly one trival path through it
    % with 0 recursive calls.
conj_recursion_data(_, _, _, _, _, [], simple_recursion_data(0.0, 0)).
conj_recursion_data(ThisClique, CallSiteMap, GoalPath, ConjNum, SuccessProb0, 
        [Conj | Conjs], RecursionData) :- 
    goal_recursion_data(ThisClique, CallSiteMap, 
        goal_path_add_at_end(GoalPath, step_conj(ConjNum)), Conj, 
        ConjRecursionData),
    (
        ConjRecursionData = proc_dead_code,
        % If the first conjunct is dead then the remaining ones will also be
        % dead.  This speeds up execution and avoids a divide by zero when
        % calculating ConjSuccessProb below.
        RecursionData = proc_dead_code
    ;
        ConjRecursionData = recursion_data(_, _, _), 
        ( 
            get_coverage_before_and_after(Conj ^ goal_annotation, Before, After)
        ->
            ( After > Before ->
                % Nondet code can overflow this probability.
                ConjSuccessProb = certain
            ;
                ConjSuccessProb = probable(float(After) / float(Before))
            )
        ;
            error(this_file ++ "expected complete coverage information")
        ), 
        SuccessProb = and(SuccessProb0, ConjSuccessProb),
        conj_recursion_data(ThisClique, CallSiteMap, GoalPath, ConjNum + 1,
            SuccessProb, Conjs, ConjsRecursionData),
        merge_recursion_data_sequence(ConjRecursionData, ConjsRecursionData,
            RecursionData)
    ).

:- pred disj_recursion_data(clique_ptr::in, 
    map(goal_path, cost_and_callees)::in, goal_path::in, int::in, 
    list(goal_rep(coverage_info))::in, recursion_data::out) is det.

disj_recursion_data(_, _, _, _, _, !:RecursionData) :-
    !:RecursionData = simple_recursion_data(0.0, 0),
    recursion_data_add_error(re_unhandled_disjunction, !RecursionData).

:- pred ite_recursion_data(clique_ptr::in, 
    map(goal_path, cost_and_callees)::in, goal_path::in, 
    goal_rep(coverage_info)::in, goal_rep(coverage_info)::in,
    goal_rep(coverage_info)::in, int::in, recursion_data::out) is det.

ite_recursion_data(ThisClique, CallSiteMap, GoalPath, Cond, Then, Else,
        Calls, !:RecursionData) :-
    goal_recursion_data(ThisClique, CallSiteMap, 
        goal_path_add_at_end(GoalPath, step_ite_cond), Cond,
        CondRecursionData),
    goal_recursion_data(ThisClique, CallSiteMap, 
        goal_path_add_at_end(GoalPath, step_ite_then), Then,
        ThenRecursionData0),
    goal_recursion_data(ThisClique, CallSiteMap,
        goal_path_add_at_end(GoalPath, step_ite_else), Else,
        ElseRecursionData0),

    % Adjust the probabilities of executing the then and else branches.
    (
        get_coverage_before(Then ^ goal_annotation, ThenCalls),
        get_coverage_before(Else ^ goal_annotation, ElseCalls)
    ->
        CallsF = float(Calls),
        ThenProb = probable(float(ThenCalls) / CallsF),
        ElseProb = probable(float(ElseCalls) / CallsF)
    ;
        error(this_file ++ "couldn't retrive coverage information")
    ),
    recursion_data_and_probability(ThenProb, ThenRecursionData0,
        ThenRecursionData),
    recursion_data_and_probability(ElseProb, ElseRecursionData0,
        ElseRecursionData),

    % Because the condition goal has coverage information as if it is
    % entered before either branch, we have to model it in the same way
    % here, even though it would be fesable to model it sas something
    % that happens in sequence with both the then and else branches
    % (within each branch).
    merge_recursion_data_after_branch(ThenRecursionData, 
        ElseRecursionData, !:RecursionData),
    merge_recursion_data_sequence(CondRecursionData, !RecursionData).

:- pred switch_recursion_data(clique_ptr::in, 
    map(goal_path, cost_and_callees)::in, goal_path::in, int::in, 
    list(case_rep(coverage_info))::in, float::in,
    recursion_data::out) is det.

switch_recursion_data(_, _, _, _, [], _, proc_dead_code).
switch_recursion_data(ThisClique, CallSiteMap, GoalPath, CaseNum, 
        [Case | Cases], TotalCalls, RecursionData) :-
    Case = case_rep(_, _, Goal),
    goal_recursion_data(ThisClique, CallSiteMap, 
        goal_path_add_at_end(GoalPath, step_switch(CaseNum, no)), Goal, 
        CaseRecursionData0),
    ( get_coverage_before(Goal ^ goal_annotation, CallsPrime) ->
        Calls = CallsPrime
    ;
        error(this_file ++ "expected coverage information")
    ),
    CaseProb = probable(float(Calls) / TotalCalls),
    recursion_data_and_probability(CaseProb, CaseRecursionData0,
        CaseRecursionData),
    switch_recursion_data(ThisClique, CallSiteMap, GoalPath, CaseNum+1,
        Cases, TotalCalls, CasesRecursionData),
    merge_recursion_data_after_branch(CaseRecursionData, CasesRecursionData,
        RecursionData).

:- pred atomic_goal_recursion_data(clique_ptr::in, 
    map(goal_path, cost_and_callees)::in, goal_path::in,
    atomic_goal_rep::in, recursion_data::out) is det.

atomic_goal_recursion_data(ThisClique, CallSiteMap, GoalPath, AtomicGoal, 
        RecursionData) :-
    (
        % All these things have trivial cost except for foreign code whose cost
        % is unknown (which because it doesn't contribute to the cost of the
        % caller we assume that it is trivial)..
        ( AtomicGoal = unify_construct_rep(_, _, _)
        ; AtomicGoal = unify_deconstruct_rep(_, _, _)
        ; AtomicGoal = partial_deconstruct_rep(_, _, _)
        ; AtomicGoal = partial_construct_rep(_, _, _)
        ; AtomicGoal = unify_assign_rep(_, _)
        ; AtomicGoal = cast_rep(_, _)
        ; AtomicGoal = unify_simple_test_rep(_, _)
        ; AtomicGoal = pragma_foreign_code_rep(_)
        ; AtomicGoal = builtin_call_rep(_, _, _)
        ; AtomicGoal = event_call_rep(_, _)
        ),
        RecursionLevel = 0 - recursion_level(0.0, certain)
    ;
        ( AtomicGoal = higher_order_call_rep(_, _)
        ; AtomicGoal = method_call_rep(_, _, _)
        ; AtomicGoal = plain_call_rep(_, _, _)
        ),

        % Get the cost of the call.
        ( map.search(CallSiteMap, GoalPath, CostAndCallees) ->
            CostAndCallees = cost_and_callees(Cost, Callees)
        ;
            Cost = 0,
            set.init(Callees)
        ),

        ( member(ThisClique, Callees) ->
            % Cost will be 1.0 for for each call to recursive calls but we
            % calculate this later.
            RecursionLevel = 1 - recursion_level(0.0, certain)
        ;
            RecursionLevel = 0 - recursion_level(float(Cost), certain)
        )
    ),
    RecursionLevel = RecursiveCalls - _,
    RecursionData = recursion_data([RecursionLevel], RecursiveCalls, init).

    % Consider the following nested switches:
    %
    % (
    %     (
    %         base1
    %     ;
    %         rec1
    %     )
    % ;
    %     (
    %         base2
    %     ;
    %         rec2
    %     )
    % )
    % 
    % + The cost of entering a base case is the weighted average of the costs
    %   of the two base cases.
    % + The number of times one enteres a base case is the sum of the
    %   individual counts.
    % + The above two rules are also true for recursive cases.
    %
:- pred merge_recursion_data_after_branch(recursion_data::in, 
    recursion_data::in, recursion_data::out) is det.

merge_recursion_data_after_branch(A, B, Result) :-
    A = recursion_data(RecursionsA, MaxLevelA, ErrorsA),
    B = recursion_data(RecursionsB, MaxLevelB, ErrorsB),
    Recursions0 = assoc_list.merge(RecursionsA, RecursionsB),
    condense_recursions(Recursions0, Recursions),
    MaxLevel = max(MaxLevelA, MaxLevelB),
    Errors = union(ErrorsA, ErrorsB),
    Result = recursion_data(Recursions, MaxLevel, Errors).
merge_recursion_data_after_branch(A, proc_dead_code, A) :-
    A = recursion_data(_, _, _).
merge_recursion_data_after_branch(proc_dead_code, A, A).

    % merge_recursion_data_sequence(A, B, Merged).
    %
    % Merge the recursion datas A and B to produce Merged.  This is not
    % commutative, A must represent something occuring before B.
    %
    % Consider the following conjoined switches.
    %
    % (
    %     base1
    % ;
    %     rec1
    % ),
    % (
    %     base2
    % ;
    %     rec2
    % )
    % 
    % It's like algabra!  Teating the conjunction as multiplication and
    % disjunction as addition we might factorise it as:
    % Note that this is just to show the pattern I can see here.
    % 
    % base1*base2 + base1*rec2 + base2*rec1 + rec1*rec2.
    %
    % That is, there is one base case, two recursive cases, and a doubly
    % recursive case.
    %
    % We have to convert counts to probabilities, then:
    %
    % + The probability of entering the base case is the product of the
    %   probabilities of entering either base case.
    % + Similarly the probability of entering any other case is the product the
    %   probabilities of their components.
    % + The cost of entering the base case is the sum of the costs of the
    %   components.
    % + Similarly for the other cases.
    %
:- pred merge_recursion_data_sequence(recursion_data::in, 
    recursion_data::in, recursion_data::out) is det.

merge_recursion_data_sequence(A, B, Result) :-
    A = recursion_data(RecursionsA, MaxLevelA, ErrorsA),
    B = recursion_data(RecursionsB, MaxLevelB, ErrorsB),
    recursions_cross_product(RecursionsA, RecursionsB, Recursions0),
    sort(Recursions0, Recursions1),
    condense_recursions(Recursions1, Recursions),
    % The maximum number of recursions on any path will be the some of the
    % maximum number of recursions on two conjoined paths since all paths are
    % conjoined in the cross product.
    MaxLevel = MaxLevelA + MaxLevelB,
    Errors = union(ErrorsA, ErrorsB),
    Result = recursion_data(Recursions, MaxLevel, Errors).
merge_recursion_data_sequence(A, proc_dead_code, proc_dead_code) :-
    A = recursion_data(_, _, _).
merge_recursion_data_sequence(proc_dead_code, _, proc_dead_code).

:- pred condense_recursions(assoc_list(int, recursion_level)::in,
    assoc_list(int, recursion_level)::out) is det.

condense_recursions([], []).
condense_recursions([Num - Rec | Pairs0], Pairs) :-
    condense_recursions_2(Num - Rec, Pairs0, Pairs).

:- pred condense_recursions_2(pair(int, recursion_level)::in, 
    assoc_list(int, recursion_level)::in,
    assoc_list(int, recursion_level)::out) is det.

condense_recursions_2(Pair, [], [Pair]).
condense_recursions_2(NumA - RecA, [NumB - RecB | Pairs0], Pairs) :-
    ( NumA = NumB ->
        RecA = recursion_level(CostA, ProbabilityA),
        RecB = recursion_level(CostB, ProbabilityB),
        weighted_average(
            map(probability_to_float, [ProbabilityA, ProbabilityB]),
            [CostA, CostB], Cost),
        Probability = or(ProbabilityA, ProbabilityB),
        Rec = recursion_level(Cost, Probability),
        condense_recursions_2(NumA - Rec, Pairs0, Pairs)
    ;
        condense_recursions([NumB - RecB | Pairs0], Pairs1),
        Pairs = [NumA - RecA | Pairs1]
    ).

    % recursions_cross_product(A, B, C).
    %
    % A X B = C <=> A.1 * B.1 + A.1 * B.2 + A.2 * B.1 + A.2 * B.2 = C
    %
    % Note that this is not commutative.  A represents a computation occuring
    % before B.
    %
:- pred recursions_cross_product(assoc_list(int, recursion_level)::in,
    assoc_list(int, recursion_level)::in,
    assoc_list(int, recursion_level)::out) is det.

recursions_cross_product([], _, []). 
recursions_cross_product([NumA - RecA | PairsA], PairsB, Pairs) :-
    recursions_cross_product_2(NumA, RecA, PairsB, InnerLoop),
    recursions_cross_product(PairsA, PairsB, OuterLoopTail),
    Pairs = InnerLoop ++ OuterLoopTail.

:- pred recursions_cross_product_2(int::in, recursion_level::in,
    assoc_list(int, recursion_level)::in,
    assoc_list(int, recursion_level)::out) is det.

recursions_cross_product_2(_Num, _Rec, [], []).
recursions_cross_product_2(NumA, RecA@recursion_level(CostA, ProbA), 
        [NumB - recursion_level(CostB, ProbB) | PairsB], Pairs) :-
    recursions_cross_product_2(NumA, RecA, PairsB, Pairs0),
    Num = NumA + NumB,
    Prob = and(ProbA, ProbB),
    Cost = CostA + CostB,
    Pair = Num - recursion_level(Cost, Prob),
    Pairs = [Pair | Pairs0].

:- pred recursion_data_and_probability(probability::in, recursion_data::in,
    recursion_data::out) is det.

recursion_data_and_probability(Prob,
        recursion_data(!.Recursions, MaxLevel, Errors),
        recursion_data(!:Recursions, MaxLevel, Errors)) :-
    map_values(recursion_level_and_probability(Prob), !Recursions).
recursion_data_and_probability(_, proc_dead_code, proc_dead_code).

:- pred recursion_level_and_probability(probability::in, T::in, 
    recursion_level::in, recursion_level::out) is det.

recursion_level_and_probability(AndProb, _, recursion_level(Cost, Prob0), 
        recursion_level(Cost, Prob)) :-
    Prob = and(Prob0, AndProb).

:- pred recursion_data_add_error(recursion_error::in, recursion_data::in,
    recursion_data::out) is det.

recursion_data_add_error(Error, !RecursionData) :-
    some [!Errors] (
        (
            !.RecursionData = recursion_data(_, _, !:Errors),
            svset.insert(Error, !Errors),
            !RecursionData ^ rd_errors := !.Errors
        ;
            !.RecursionData = proc_dead_code
        )
    ).

    % simple_recursion_data(Cost, RecCalls) = RecursionData.
    %
    % Create a simple recursion data item from a single level.
    %
:- func simple_recursion_data(float, int) = recursion_data.

simple_recursion_data(Cost, Calls) = 
    recursion_data([Calls - recursion_level(Cost, certain)], Calls, init).

:- func error_to_string(recursion_error) = string.

error_to_string(re_unhandled_determinism(Detism)) = 
    format("%s code is not handled", [s(string(Detism))]).
error_to_string(re_unhandled_disjunction) = 
    "Disjunctions are not currently handled".

%----------------------------------------------------------------------------%

create_recursion_types_frequency_report(Deep, MaybeReport) :-
    % This report is impossible without procrep data, but we don't use it
    % directly.
    MaybeProgRepResult = Deep ^ procrep_file,
    (
        MaybeProgRepResult = no,
        MaybeReport = error("There is no readable " ++
            "procedure representation information file.")
    ;
        MaybeProgRepResult = yes(error(Error)),
        MaybeReport = error("Error reading procedure representation " ++
            "information file: " ++ Error)
    ;
        MaybeProgRepResult = yes(ok(_)),
        Cliques = Deep ^ clique_index,
        size(Cliques, NumCliques),  
        array_foldl_from_1(rec_types_freq_build_histogram(Deep), Cliques, 
            map.init, Histogram0),
        finalize_histogram(Deep, NumCliques, Histogram0, Histogram),
        MaybeReport = ok(recursion_types_frequency_report(Histogram))
    ).

:- pred rec_types_freq_build_histogram(deep::in, int::in, clique_ptr::in,
    map(recursion_type_simple, recursion_type_raw_freq_data)::in, 
    map(recursion_type_simple, recursion_type_raw_freq_data)::out) is det. 

rec_types_freq_build_histogram(Deep, _, CliquePtr, !Histogram) :-
    trace [io(!IO)] (
        clique_ptr(CliqueNum) = CliquePtr,
        io.format("Analyzing clique: %d\n", [i(CliqueNum)], !IO)
    ),
    create_clique_recursion_costs_report(Deep, CliquePtr,
        MaybeCliqueRecursionReport),
    (
        MaybeCliqueRecursionReport = ok(CliqueRecursionReport),
        Type = CliqueRecursionReport ^ crr_recursion_type,
        solutions(recursion_type_to_simple_type(Type), SimpleTypes)
    ;
        MaybeCliqueRecursionReport = error(Error),
        SimpleTypes = [rts_error(Error), rts_total_error_instances]
    ),
    find_clique_first_and_other_procs(Deep, CliquePtr, MaybeFirstPDPtr,
        _OtherPDPtrs),
    (
        MaybeFirstPDPtr = yes(FirstPDPtr),
        lookup_proc_dynamics(Deep ^ proc_dynamics, FirstPDPtr, FirstPD),
        FirstPSPtr = FirstPD ^ pd_proc_static,  
        PDesc = describe_proc(Deep, FirstPSPtr), 
        lookup_pd_own(Deep ^ pd_own, FirstPDPtr, ProcOwn),
        lookup_pd_desc(Deep ^ pd_desc, FirstPDPtr, ProcInherit),
        FirstProcInfo = first_proc_info(PDesc, 
            own_and_inherit_prof_info(ProcOwn, ProcInherit)),
        MaybeFirstProcInfo = yes(FirstProcInfo)
    ;
        MaybeFirstPDPtr = no,
        MaybeFirstProcInfo = no
    ),
    foldl(update_histogram(MaybeFirstProcInfo), SimpleTypes, !Histogram).
            
:- type first_proc_info
    --->    first_proc_info(
                fpi_pdesc               :: proc_desc,
                fpi_prof_info           :: own_and_inherit_prof_info
            ).

    % XXX: Consider moving this to measuerments.m
    %
:- type own_and_inherit_prof_info
    --->    own_and_inherit_prof_info(
                oai_own                 :: own_prof_info,
                oai_inherit             :: inherit_prof_info
            ).

:- pred add_own_and_inherit_prof_info(own_and_inherit_prof_info::in,
    own_and_inherit_prof_info::in, own_and_inherit_prof_info::out) is det.

add_own_and_inherit_prof_info(
        own_and_inherit_prof_info(OwnA, InheritA),
        own_and_inherit_prof_info(OwnB, InheritB),
        own_and_inherit_prof_info(Own, Inherit)) :-
    Own = add_own_to_own(OwnA, OwnB),
    Inherit = add_inherit_to_inherit(InheritA, InheritB).

:- type recursion_type_raw_freq_data
    --->    recursion_type_raw_freq_data(
                rtrfd_freq              :: int,
                rtrfd_maybe_prof_info   :: maybe(own_and_inherit_prof_info),
                rtrfd_entry_procs       :: map(proc_static_ptr, 
                    recursion_type_raw_proc_freq_data)
            ).

:- type recursion_type_raw_proc_freq_data
    --->    recursion_type_raw_proc_freq_data(
                rtrpfd_freq             :: int,
                rtrpfd_prof_info        :: own_and_inherit_prof_info,
                rtrpfd_proc_desc        :: proc_desc
            ).

:- pred update_histogram(maybe(first_proc_info)::in,
    recursion_type_simple::in, 
    map(recursion_type_simple, recursion_type_raw_freq_data)::in, 
    map(recursion_type_simple, recursion_type_raw_freq_data)::out) is det.

update_histogram(MaybeFirstProcInfo, SimpleType, !Histogram) :-
    ( map.search(!.Histogram, SimpleType, Data0) ->
        Data0 = recursion_type_raw_freq_data(Count0, MaybeProfInfo0, Procs0),
        (
            MaybeFirstProcInfo = yes(FirstProcInfo),
            (
                MaybeProfInfo0 = yes(ProfInfo0),
                add_own_and_inherit_prof_info(FirstProcInfo ^ fpi_prof_info, 
                    ProfInfo0, ProfInfo)
            ;
                MaybeProfInfo0 = no,
                ProfInfo = FirstProcInfo ^ fpi_prof_info
            ),
            MaybeProfInfo = yes(ProfInfo),
            update_procs_map(FirstProcInfo, Procs0, Procs)
        ;
            MaybeFirstProcInfo = no,
            MaybeProfInfo = MaybeProfInfo0,
            Procs = Procs0
        ),
        Count = Count0 + 1,
        Data = recursion_type_raw_freq_data(Count, MaybeProfInfo, Procs)
    ;
        Count = 1,
        (
            MaybeFirstProcInfo = yes(FirstProcInfo),
            MaybeProfInfo = yes(FirstProcInfo ^ fpi_prof_info),
            update_procs_map(FirstProcInfo, map.init, Procs)
        ;
            MaybeFirstProcInfo = no,
            MaybeProfInfo = no,
            Procs = map.init
        ),
        Data = recursion_type_raw_freq_data(Count, MaybeProfInfo, Procs)
    ),
    svmap.set(SimpleType, Data, !Histogram).

:- pred update_procs_map(first_proc_info::in,
    map(proc_static_ptr, recursion_type_raw_proc_freq_data)::in, 
    map(proc_static_ptr, recursion_type_raw_proc_freq_data)::out) is det.

update_procs_map(FirstProcInfo, !Map) :-
    FirstProcInfo = first_proc_info(PSDesc, FirstProfInfo),
    PsPtr = PSDesc ^ pdesc_ps_ptr,
    ( map.search(!.Map, PsPtr, ProcFreqData0) ->
        ProcFreqData0 = 
            recursion_type_raw_proc_freq_data(Count0, ProfInfo0, ProcDesc),
        add_own_and_inherit_prof_info(FirstProfInfo, ProfInfo0, ProfInfo),
        Count = Count0 + 1,
        ProcFreqData = 
            recursion_type_raw_proc_freq_data(Count, ProfInfo, ProcDesc)
    ;
        ProcFreqData = 
            recursion_type_raw_proc_freq_data(1, FirstProfInfo, PSDesc)
    ),
    svmap.set(PsPtr, ProcFreqData, !Map).

:- pred recursion_type_to_simple_type(recursion_type::in, 
    recursion_type_simple::out) is multi.

recursion_type_to_simple_type(rt_not_recursive, rts_not_recursive).
recursion_type_to_simple_type(rt_single(_, _), rts_single).
recursion_type_to_simple_type(rt_divide_and_conquer(_, _),
    rts_divide_and_conquer).
recursion_type_to_simple_type(rt_mutual_recursion(NumProcs),
    rts_mutual_recursion(NumProcs)).
recursion_type_to_simple_type(rt_other(Levels), rts_other(SimpleLevels)) :-
    SimpleLevels = set.from_list(
        map((func(Level) = Level ^ rlr_level), Levels)).
recursion_type_to_simple_type(rt_errors(Errors), rts_error(Error)) :-
    member(Error, Errors).
recursion_type_to_simple_type(rt_errors(_), rts_total_error_instances).

:- pred finalize_histogram(deep::in, int::in, 
    map(recursion_type_simple, recursion_type_raw_freq_data)::in,
    map(recursion_type_simple, recursion_type_freq_data)::out) is det. 

finalize_histogram(Deep, NumCliques, !Histogram) :-
    map_values(finalize_histogram_rec_type(Deep, float(NumCliques)), 
        !Histogram).

:- pred finalize_histogram_rec_type(deep::in, float::in, 
    recursion_type_simple::in,
    recursion_type_raw_freq_data::in, recursion_type_freq_data::out) is det.

finalize_histogram_rec_type(Deep, NumCliques, _RecursionType, 
        recursion_type_raw_freq_data(Freq, MaybeProfInfo, !.EntryProcs),
        recursion_type_freq_data(Freq, Percent, MaybeSummary, !:EntryProcs)) :-
    Percent = percent(float(Freq) / NumCliques),
    (
        MaybeProfInfo = no,
        MaybeSummary = no
    ;
        MaybeProfInfo = yes(ProfInfo),
        ProfInfo = own_and_inherit_prof_info(Own, Inherit),
        own_and_inherit_to_perf_row_data(Deep, unit, Own, Inherit, Summary), 
        MaybeSummary = yes(Summary)
    ),
    map_values(finalize_histogram_proc_rec_type(Deep, NumCliques), !EntryProcs).

:- pred finalize_histogram_proc_rec_type(deep::in, float::in,
    proc_static_ptr::in,
    recursion_type_raw_proc_freq_data::in, recursion_type_proc_freq_data::out)
    is det.

finalize_histogram_proc_rec_type(Deep, NumCliques, _PSPtr,
        recursion_type_raw_proc_freq_data(Freq, ProfInfo, ProcDesc),
        recursion_type_proc_freq_data(Freq, Percent, Summary)) :-
    Percent = percent(float(Freq) / NumCliques),
    ProfInfo = own_and_inherit_prof_info(Own, Inherit),
    own_and_inherit_to_perf_row_data(Deep, ProcDesc, Own, Inherit, Summary).

%----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "recursion_patterns.m: ".

%----------------------------------------------------------------------------%
:- end_module recursion_patterns.
%----------------------------------------------------------------------------%