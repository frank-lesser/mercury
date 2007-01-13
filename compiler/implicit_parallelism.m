%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2006 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
% 
% File : implicit_parallelism.m.
% Author: tannier.
% 
% This module uses deep profiling feedback information generated by 
% mdprof_feedback to introduce parallel conjunctions where it could be 
% worthwhile (implicit parallelism). It deals with both independent and 
% dependent parallelism.
%
% TODO 
%   -   Once a call which is a candidate for implicit parallelism is found, 
%       search forward AND backward for the closest goal which is also a 
%       candidate for implicit parallelism/parallel conjunction and determine 
%       which side is the best (on the basis of the number of shared variables).
%
%-----------------------------------------------------------------------------%

:- module transform_hlds.implicit_parallelism.
:- interface.

:- import_module hlds.hlds_module.

:- import_module io.

%-----------------------------------------------------------------------------%

    % apply_implicit_parallelism_transformation(!ModuleInfo, FeedbackFile, !IO)
    %
    % Apply the implicit parallelism transformation using the specified
    % feedback file.
    %
:- pred apply_implicit_parallelism_transformation(
    module_info::in, module_info::out, string::in, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module check_hlds.inst_match.
:- import_module hlds.hlds_goal.
:- import_module check_hlds.mode_util.
:- import_module hlds.goal_util.
:- import_module hlds.hlds_pred.
:- import_module hlds.instmap.
:- import_module hlds.quantification.
:- import_module libs.compiler_util.
:- import_module mdbcomp.prim_data.
:- import_module parse_tree.error_util.
:- import_module parse_tree.prog_data.
:- import_module transform_hlds.dep_par_conj.

:- import_module bool.
:- import_module char.
:- import_module counter.
:- import_module int.
:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module require.
:- import_module set.
:- import_module string.

%-----------------------------------------------------------------------------%

    % Represent a call site static which is a candidate for introducing
    % implicit parallelism.
    %
:- type candidate_call_site
    --->    candidate_call_site(
                caller      :: string,          % The caller of the call.
                slot_number :: int,             % The slot number of the call.
                kind        :: call_site_kind,  % The kind of the call.
                callee      :: string           % The callee of the call.
            ).

    % Represent the kind of a call site.
    %
:- type call_site_kind
        --->    csk_normal
        ;       csk_special
        ;       csk_higher_order
        ;       csk_method
        ;       csk_callback. 

    % Construct a call_site_kind from its string representation.
    %
:- pred construct_call_site_kind(string::in, call_site_kind::out) is semidet.

construct_call_site_kind("normal_call",         csk_normal).
construct_call_site_kind("special_call",        csk_special).
construct_call_site_kind("higher_order_call",   csk_higher_order).
construct_call_site_kind("method_call",         csk_method).
construct_call_site_kind("callback",            csk_callback).

%-----------------------------------------------------------------------------%

apply_implicit_parallelism_transformation(!ModuleInfo, FeedbackFile, !IO) :-
    parse_feedback_file(FeedbackFile, MaybeCandidateCallSites, !IO),
    ( 
        MaybeCandidateCallSites = error(Error),
        io.stderr_stream(Stderr, !IO),
        io.write_string(Stderr, Error ++ "\n", !IO)
    ;
        MaybeCandidateCallSites = ok(CandidateCallSites),
        module_info_predids(!.ModuleInfo, PredIds),
        process_preds_for_implicit_parallelism(PredIds,
            CandidateCallSites, !ModuleInfo)
    ).

    % Process predicates for implicit parallelism.
    %
:- pred process_preds_for_implicit_parallelism(list(pred_id)::in,
    list(candidate_call_site)::in, module_info::in, module_info::out) 
    is det.

process_preds_for_implicit_parallelism([], _ListCandidateCallSite, 
        !ModuleInfo).
process_preds_for_implicit_parallelism([ PredId | PredIdList ], 
        ListCandidateCallSite, !ModuleInfo) :-
    module_info_pred_info(!.ModuleInfo, PredId, PredInfo),
    ProcIds = pred_info_non_imported_procids(PredInfo),    
    process_procs_for_implicit_parallelism(PredId, ProcIds,
        ListCandidateCallSite, !ModuleInfo),
    process_preds_for_implicit_parallelism(PredIdList,
        ListCandidateCallSite, !ModuleInfo).

    % Process procedures for implicit parallelism.
    %
:- pred process_procs_for_implicit_parallelism(pred_id::in,
    list(proc_id)::in, list(candidate_call_site)::in, 
    module_info::in, module_info::out) is det.

process_procs_for_implicit_parallelism(_PredId, [],
        _ListCandidateCallSite, !ModuleInfo).
process_procs_for_implicit_parallelism(PredId, [ ProcId | ProcIds ],
        ListCandidateCallSite, !ModuleInfo) :-
    module_info_pred_proc_info(!.ModuleInfo, PredId, ProcId,
        PredInfo0, ProcInfo0),
    % Initialize the counter for the slot number.
    SiteNumCounter = counter.init(0),
    pred_proc_id_to_raw_id(PredInfo0, ProcId, CallerRawId),
    get_callees_feedback(CallerRawId, ListCandidateCallSite, [], 
        CallSites),
    list.length(CallSites, NumCallSites),
    ( NumCallSites = 0 -> 
        % No candidate calls for implicit parallelism in this procedure.
        process_procs_for_implicit_parallelism(PredId, ProcIds,
            ListCandidateCallSite, !ModuleInfo)
    ;
        proc_info_get_goal(ProcInfo0, Body0),
        process_goal_for_implicit_parallelism(Body0, Body, ProcInfo0, 
            !ModuleInfo, no, _, 0, _, CallSites, _, SiteNumCounter, _),
        proc_info_set_goal(Body, ProcInfo0, ProcInfo1),            
        proc_info_set_has_parallel_conj(yes, ProcInfo1, ProcInfo2), 
        requantify_proc(ProcInfo2, ProcInfo3),
        RecomputeAtomic = no,
        recompute_instmap_delta_proc(RecomputeAtomic, ProcInfo3, ProcInfo, 
            !ModuleInfo),
        pred_info_set_proc_info(ProcId, ProcInfo, PredInfo0, PredInfo),
        module_info_set_pred_info(PredId, PredInfo, !ModuleInfo),
        process_procs_for_implicit_parallelism(PredId, ProcIds,
            ListCandidateCallSite, !ModuleInfo)
    ).

    % Filter the list of call site information from the feedback file so that 
    % the resulting list only contains those call sites that belong to the first
    % argument, e.g. the caller. 
    %
:- pred get_callees_feedback(string::in, list(candidate_call_site)::in,
    list(candidate_call_site)::in, list(candidate_call_site)::out) is det.

get_callees_feedback(_Caller, [], !ResultAcc).
get_callees_feedback(Caller, [ CandidateCallSite | ListCandidateCallSite ], 
        !ResultAcc) :-
    CandidateCallSite = candidate_call_site(CSSCaller, _, _, _),
    ( Caller = CSSCaller ->
        !:ResultAcc = [ CandidateCallSite | !.ResultAcc ],
        get_callees_feedback(Caller, ListCandidateCallSite, !ResultAcc)
    ;
        get_callees_feedback(Caller, ListCandidateCallSite, !ResultAcc)
    ).

    % Process a goal for implicit parallelism.
    % MaybeConj is the conjunction which contains Goal.
    %
:- pred process_goal_for_implicit_parallelism(hlds_goal::in, hlds_goal::out,
    proc_info::in, module_info::in, module_info::out,
    maybe(hlds_goal_expr)::in, maybe(hlds_goal_expr)::out, int ::in, int::out, 
    list(candidate_call_site)::in, list(candidate_call_site)::out, 
    counter::in, counter::out) is det.

process_goal_for_implicit_parallelism(!Goal, ProcInfo, !ModuleInfo, 
    !MaybeConj, !IndexInConj, !CalleeListToBeParallelized, !SiteNumCounter) :- 
    !.Goal = hlds_goal(GoalExpr0, GoalInfo),
    (
        GoalExpr0 = unify(_, _, _, _, _),
        increment_index_if_in_conj(!.MaybeConj, !IndexInConj)    
    ;
        GoalExpr0 = plain_call(_, _, _, _, _, _),
        process_call_for_implicit_parallelism(!.Goal, ProcInfo, !ModuleInfo,
            !IndexInConj, !MaybeConj, !CalleeListToBeParallelized, 
            !SiteNumCounter)
        % We deal with the index in the conjunction in 
        % process_call_for_implicit_parallelism.
    ;
        GoalExpr0 = call_foreign_proc(_, _, _, _, _, _, _),
        process_call_for_implicit_parallelism(!.Goal, ProcInfo, !ModuleInfo,
            !IndexInConj, !MaybeConj, !CalleeListToBeParallelized, 
            !SiteNumCounter)
    ;
        GoalExpr0 = generic_call(Details, _, _, _),
        (
            Details = higher_order(_, _, _, _),
            process_call_for_implicit_parallelism(!.Goal, ProcInfo, 
                !ModuleInfo, !IndexInConj, !MaybeConj, 
                !CalleeListToBeParallelized, !SiteNumCounter)  
        ;
            Details = class_method(_, _, _, _),
            process_call_for_implicit_parallelism(!.Goal, ProcInfo, 
                !ModuleInfo, !IndexInConj, !MaybeConj, 
                !CalleeListToBeParallelized, !SiteNumCounter)
        ;
            Details = event_call(_),
            increment_index_if_in_conj(!.MaybeConj, !IndexInConj)    
        ;
            Details = cast(_),
            increment_index_if_in_conj(!.MaybeConj, !IndexInConj)    
        )
    ;
        % No distinction is made between plain conjunctions and parallel 
        % conjunctions. We have to process the parallel conjunction for the 
        % slot number.
        GoalExpr0 = conj(_, _),
        process_conj_for_implicit_parallelism(GoalExpr0, GoalExpr, 1, 
            ProcInfo, !ModuleInfo, !CalleeListToBeParallelized, 
            !SiteNumCounter),
        % A plain conjunction will never be contained in an other plain 
        % conjunction. As for parallel conjunctions, they will not 
        % be modified. Therefore, incrementing the index suffices (no need to 
        % call update_conj_and_index).
        !:Goal = hlds_goal(GoalExpr, GoalInfo),
        increment_index_if_in_conj(!.MaybeConj, !IndexInConj)
    ;
        GoalExpr0 = disj(Goals0),
        process_disj_for_implicit_parallelism(Goals0, [], Goals, 
            ProcInfo, !ModuleInfo, !CalleeListToBeParallelized, 
            !SiteNumCounter),
        GoalProcessed = hlds_goal(disj(Goals), GoalInfo),
        update_conj_and_index(!MaybeConj, GoalProcessed, !IndexInConj),
        % If we are not in a conjunction, then we need to return the modified 
        % value of Goal. In we are in a conjunction, that information is not
        % read (see process_conj_for_implicit_parallelism). 
        !:Goal = GoalProcessed
    ;
        GoalExpr0 = switch(Var, CanFail, Cases0),
        process_switch_cases_for_implicit_parallelism(Cases0, [], Cases, 
            ProcInfo, !ModuleInfo, !CalleeListToBeParallelized, 
            !SiteNumCounter),
        GoalProcessed = hlds_goal(switch(Var, CanFail, Cases), GoalInfo),
        update_conj_and_index(!MaybeConj, GoalProcessed, !IndexInConj),
        !:Goal = GoalProcessed
    ;
        GoalExpr0 = negation(Goal0),
        process_goal_for_implicit_parallelism(Goal0, Goal, ProcInfo, 
            !ModuleInfo, !MaybeConj, !IndexInConj, !CalleeListToBeParallelized, 
            !SiteNumCounter),
        GoalProcessed = hlds_goal(negation(Goal), GoalInfo),
        update_conj_and_index(!MaybeConj, GoalProcessed, !IndexInConj),
        !:Goal = GoalProcessed
    ;
        GoalExpr0 = scope(Reason, Goal0),
        % 0 is the default value when we are not in a conjunction (in this case 
        % a scope).
        process_goal_for_implicit_parallelism(Goal0, Goal, ProcInfo, 
            !ModuleInfo, no, _, 0, _, !CalleeListToBeParallelized, 
            !SiteNumCounter),
        GoalProcessed = hlds_goal(scope(Reason, Goal), GoalInfo),
        update_conj_and_index(!MaybeConj, GoalProcessed, !IndexInConj),
        !:Goal = GoalProcessed
    ;
        GoalExpr0 = if_then_else(Vars, Cond0, Then0, Else0),
        process_goal_for_implicit_parallelism(Cond0, Cond, ProcInfo, 
            !ModuleInfo, no, _, 0, _, !CalleeListToBeParallelized, 
            !SiteNumCounter),
        process_goal_for_implicit_parallelism(Then0, Then, ProcInfo, !ModuleInfo
            , no, _, 0, _, !CalleeListToBeParallelized, !SiteNumCounter),
        process_goal_for_implicit_parallelism(Else0, Else, ProcInfo, !ModuleInfo
            , no, _, 0, _, !CalleeListToBeParallelized, !SiteNumCounter),
        GoalProcessed = hlds_goal(if_then_else(Vars, Cond, Then, Else),
            GoalInfo), 
        update_conj_and_index(!MaybeConj, GoalProcessed, !IndexInConj), 
        !:Goal = GoalProcessed
    ;
        GoalExpr0 = shorthand(_),
        increment_index_if_in_conj(!.MaybeConj, !IndexInConj)    
    ).

    % Increment the index if we are in a conjunction.
    %
:- pred increment_index_if_in_conj(maybe(hlds_goal_expr)::in, int::in, int::out)
    is det.

increment_index_if_in_conj(MaybeConj, !IndexInConj) :-
    ( 
        MaybeConj = yes(_), 
        !:IndexInConj = !.IndexInConj + 1
    ;
        MaybeConj = no
    ).

    % Process a call for implicit parallelism.
    %
:- pred process_call_for_implicit_parallelism(hlds_goal::in, proc_info::in,
    module_info::in, module_info::out, int::in, int::out, 
    maybe(hlds_goal_expr)::in, maybe(hlds_goal_expr)::out, 
    list(candidate_call_site)::in, list(candidate_call_site)::out, 
    counter::in, counter::out) is det.
    
process_call_for_implicit_parallelism(Call, ProcInfo, !ModuleInfo, !IndexInConj
    , !MaybeConj, !CalleeListToBeParallelized, !SiteNumCounter) :-
    counter.allocate(SlotNumber, !SiteNumCounter),
    get_call_kind_and_callee(!.ModuleInfo, Call, Kind, CalleeRawId),
    (
        !.MaybeConj = yes(Conj0), Conj0 = conj(plain_conj, ConjGoals0)
    ->
        (
            is_in_css_list_to_be_parallelized(Kind, SlotNumber, CalleeRawId, 
                !.CalleeListToBeParallelized, [], !:CalleeListToBeParallelized)
        ->  
            (
                build_goals_surrounded_by_calls_to_be_parallelized(ConjGoals0, 
                    !.ModuleInfo, [ Call ], Goals, !.IndexInConj + 1, End, 
                    !SiteNumCounter, !CalleeListToBeParallelized)
            ->
                parallelize_calls(Goals, !.IndexInConj, End, Conj0, Conj, 
                    ProcInfo, !ModuleInfo),
                !:IndexInConj = End,
                !:MaybeConj = yes(Conj)
            ;
                % The next call is not in the feedback file or we've hit a 
                % plain conjunction/disjunction/switch/if then else.
                !:IndexInConj = !.IndexInConj + 1
            )
        ;
            % Not to be parallelized.
            !:IndexInConj = !.IndexInConj + 1
        )
    ;
        % Call is not in a conjunction or the call is already in a parallel 
        % conjunction.
        true
    ).      

    % Give the raw id (the same as in the deep profiler) of a callee contained 
    % in a call.
    %
:- pred get_call_kind_and_callee(module_info::in, hlds_goal::in, 
    call_site_kind::out, string::out) is det.

get_call_kind_and_callee(ModuleInfo, Call, Kind, CalleeRawId) :-
    GoalExpr = Call ^ hlds_goal_expr,
    (
        GoalExpr = plain_call(PredId, ProcId, _, _, _, _)
    ->
        module_info_pred_proc_info(ModuleInfo, PredId, ProcId,
            PredInfo, _),
        pred_proc_id_to_raw_id(PredInfo, ProcId, CalleeRawId),
        Kind = csk_normal
    ;
        (
            GoalExpr = call_foreign_proc(_, PredId, ProcId, _, _, _, _)
        ->
            module_info_pred_proc_info(ModuleInfo, PredId, ProcId,
                PredInfo, _),
            pred_proc_id_to_raw_id(PredInfo, ProcId, CalleeRawId),
            Kind = csk_special
        ;
            (
                GoalExpr = generic_call(Details, _, _, _)
            ->
                (
                    Details = higher_order(_, _, _, _),
                    CalleeRawId = "",
                    Kind = csk_higher_order
                ;
                    Details = class_method(_, _, _, _),
                    CalleeRawId = "",
                    Kind = csk_method
                ;
                    Details = event_call(_),
                    unexpected(this_file, "get_call_kind_and_callee")
                ;
                    Details = cast(_),
                    unexpected(this_file, "get_call_kind_and_callee")
                )
            ;
                unexpected(this_file, "get_call_kind_and_callee")
            )
        )
    ).

    % Convert a pred_info and a proc_id to the raw procedure id (the same used 
    % in the deep profiler).
    %
:- pred pred_proc_id_to_raw_id(pred_info::in, proc_id::in, string::out) is det.

pred_proc_id_to_raw_id(PredInfo, ProcId, RawId) :-
    ModuleName = pred_info_module(PredInfo),
    Name = pred_info_name(PredInfo),
    OrigArity = pred_info_orig_arity(PredInfo),
    IsPredOrFunc = pred_info_is_pred_or_func(PredInfo),
    ModuleString = sym_name_to_string(ModuleName),
    ProcIdInt = proc_id_to_int(ProcId),
    RawId = string.append_list([ ModuleString, ".", Name, "/", 
        string.int_to_string(OrigArity), 
        ( IsPredOrFunc = function -> "+1" ; ""), "-", 
        string.from_int(ProcIdInt) ]).

    % Succeeds if the caller, slot number and callee correspond to a 
    % candidate_call_site in the list given as a parameter. 
    % Fail otherwise.
    %
:- pred is_in_css_list_to_be_parallelized(call_site_kind::in, int::in, 
    string::in, list(candidate_call_site)::in,
    list(candidate_call_site)::in, list(candidate_call_site)::out) 
    is semidet.

is_in_css_list_to_be_parallelized(Kind, SlotNumber, CalleeRawId, 
    ListCandidateCallSite, !ResultAcc) :-
    ( 
        ListCandidateCallSite = [],
        fail
    ;
        ListCandidateCallSite = [ CandidateCallSite | 
            ListCandidateCallSite0 ],
        CandidateCallSite = candidate_call_site(_, CSSSlotNumber, CSSKind, 
            CSSCallee),
        % =< because there is not a one to one correspondance with the source 
        % code. New calls might have been added by the previous passes of the 
        % compiler.
        ( CSSSlotNumber =< SlotNumber, CSSKind = Kind, CSSCallee = CalleeRawId
        ->
            list.append(!.ResultAcc, ListCandidateCallSite0, !:ResultAcc)
        ;
            list.append(!.ResultAcc, [ CandidateCallSite ], !:ResultAcc),
            is_in_css_list_to_be_parallelized(Kind, SlotNumber, CalleeRawId, 
                ListCandidateCallSite0, !ResultAcc)
        )
    ).

    % Build a list of goals surrounded by two calls which are in the feedback 
    % file or by a call which is in the feedback file and a parallel 
    % conjunction.
    % 
    % Succeed if we can build that list of goals.
    % Fail otherwise.
    %
:- pred build_goals_surrounded_by_calls_to_be_parallelized(list(hlds_goal)::in,
    module_info::in, list(hlds_goal)::in, list(hlds_goal)::out, 
    int::in, int::out, counter::in, counter::out, 
    list(candidate_call_site)::in, list(candidate_call_site)::out) 
    is semidet.

build_goals_surrounded_by_calls_to_be_parallelized(ConjGoals, ModuleInfo, 
        !ResultAcc, !Index, !SiteNumCounter, !CalleeListToBeParallelized) :-
    list.length(ConjGoals, Length),
    ( !.Index > Length ->
        fail
    ;
        list.index1_det(ConjGoals, !.Index, Goal),
        GoalExpr = Goal ^ hlds_goal_expr,
        ( 
            ( GoalExpr = disj(_)
            ; GoalExpr = switch(_, _, _)
            ; GoalExpr = if_then_else(_, _, _, _)
            ; GoalExpr = conj(plain_conj, _)
            )
        ->
            fail
        ;
            ( goal_is_conjunction(Goal, parallel_conj) ->
                list.append(!.ResultAcc, [ Goal ], !:ResultAcc)
            ;
                ( goal_is_call_or_negated_call(Goal) -> 
                    counter.allocate(SlotNumber, !SiteNumCounter),
                    get_call_kind_and_callee(ModuleInfo, Goal, Kind, 
                        CalleeRawId),
                    ( is_in_css_list_to_be_parallelized(Kind, SlotNumber, 
                        CalleeRawId, !.CalleeListToBeParallelized, [], 
                        !:CalleeListToBeParallelized)
                    ->
                        list.append(!.ResultAcc, [ Goal ], !:ResultAcc)
                    ;
                        list.append(!.ResultAcc, [ Goal ], !:ResultAcc),
                        !:Index = !.Index + 1,
                        build_goals_surrounded_by_calls_to_be_parallelized(
                            ConjGoals, ModuleInfo, !ResultAcc, !Index, 
                            !SiteNumCounter, !CalleeListToBeParallelized)
                    )
                ;
                    list.append(!.ResultAcc, [ Goal ], !:ResultAcc),
                    !:Index = !.Index + 1,
                    build_goals_surrounded_by_calls_to_be_parallelized(
                        ConjGoals, ModuleInfo, !ResultAcc, !Index, 
                        !SiteNumCounter, !CalleeListToBeParallelized)
                )
            )
        )
    ).

    % Succeeds if Goal is a conjunction and return the type of the
    % conjunction.  Fail otherwise.
    %
:- pred goal_is_conjunction(hlds_goal::in, conj_type::out) is semidet.

goal_is_conjunction(Goal, Type) :-
    GoalExpr = Goal ^ hlds_goal_expr,
    GoalExpr = conj(Type, _).

    % Succeed if Goal is a call or a negated call.
    % Call here includes higher-order and class method calls.
    % Fail otherwise.
    %
:- pred goal_is_call_or_negated_call(hlds_goal::in) is semidet.
    
goal_is_call_or_negated_call(Goal) :-
    GoalExpr = Goal ^ hlds_goal_expr,
    (
        GoalExpr = plain_call(_, _, _, _, _, _)
    ;
        GoalExpr = call_foreign_proc(_, _, _, _, _, _, _)
    ;
        GoalExpr = generic_call(Details, _, _, _),
        (
            Details = class_method(_, _, _, _)
        ;
            Details = higher_order(_, _, _, _)
        )
    ;
        GoalExpr = negation(GoalNeg),
        GoalNegExpr = GoalNeg ^ hlds_goal_expr,
        (
            GoalNegExpr = plain_call(_, _, _, _, _, _)
        ;
            GoalNegExpr = call_foreign_proc(_, _, _, _, _, _, _)
        ;
            GoalNegExpr = generic_call(Details, _, _, _),
            (
                Details = class_method(_, _, _, _)
            ;
                Details = higher_order(_, _, _, _)
            )
        )
    ).

    % Parallelize two calls/a call and a parallel conjunction which might have 
    % goals between them. If these have no dependencies with the first call then
    % we move them before the first call and parallelize the two calls/call and 
    % parallel conjunction.
    %
    % Goals is contained in Conj.
    %
:- pred parallelize_calls(list(hlds_goal)::in, int::in, int::in, 
    hlds_goal_expr::in, hlds_goal_expr::out, proc_info::in, 
    module_info::in, module_info::out) is det.

parallelize_calls(Goals, Start, End, !Conj, ProcInfo, !ModuleInfo) :-
    ( !.Conj = conj(plain_conj, ConjGoals0) ->
        ( ConjGoals0 = [ FirstGoal, LastGoal ] ->
            ( is_worth_parallelizing(FirstGoal, LastGoal, ProcInfo, 
                !.ModuleInfo) 
            ->
                ( goal_is_conjunction(LastGoal, parallel_conj) ->
                    % The parallel conjunction has to remain flatened.
                    add_call_to_parallel_conjunction(FirstGoal, LastGoal, 
                        ParallelGoal),
                    !:Conj = ParallelGoal ^ hlds_goal_expr
                ;
                    !:Conj = conj(parallel_conj, ConjGoals0)
                )
            ;
                % Not worth parallelizing.
                true
            )
        ;
            % There are more than two goals in the conjunction.
            list.length(Goals, Length),
            list.index1_det(Goals, 1, FirstGoal),
            list.index1_det(Goals, Length, LastGoal),
            ( is_worth_parallelizing(FirstGoal, LastGoal, ProcInfo, 
                !.ModuleInfo) 
            ->
                GoalsInBetweenAndLast = list.det_tail(Goals),
                list.delete_all(GoalsInBetweenAndLast, LastGoal, 
                    GoalsInBetween),    
                % Check the dependencies of GoalsInBetween with FirstGoal.
                list.filter(goal_depends_on_goal(FirstGoal), 
                    GoalsInBetween, GoalsFiltered),
                ( list.is_empty(GoalsFiltered) ->
                    ( goal_is_conjunction(LastGoal, parallel_conj) ->
                        add_call_to_parallel_conjunction(FirstGoal, LastGoal, 
                            ParallelGoal)
                    ;
                        create_conj(FirstGoal, LastGoal, parallel_conj, 
                            ParallelGoal)
                    ),
                    ( Start = 1 ->
                        GoalsFront = []
                    ;
                        list.det_split_list(Start - 1, ConjGoals0, 
                            GoalsFront, _)
                    ),
                    list.length(ConjGoals0, ConjLength),
                    ( End = ConjLength ->
                        GoalsBack = []
                    ;
                        list.det_split_list(End, ConjGoals0, _, 
                            GoalsBack)
                    ),
                    list.append(GoalsFront, GoalsInBetween, 
                        GoalsFrontWithBetween),
                    list.append(GoalsFrontWithBetween, [ ParallelGoal ], 
                        GoalsWithoutBack),
                    list.append(GoalsWithoutBack, GoalsBack, ConjGoals),
                    !:Conj = conj(plain_conj, ConjGoals)
                ;
                    % The goals between the two calls/call and parallel 
                    % conjunction can't be moved before the first call.
                    true
                )
            ;
                % Not worth parallelizing.
                true
            )
        )
    ;
        % Conj is not a conjunction.
        unexpected(this_file, "parallelize_calls")
    ).

    % Two calls are worth parallelizing if the number of shared variables is 
    % smaller than the number of argument variables of at least one of the two 
    % calls.
    %
    % A call and a parallel conjunction are worth parallelizing if the number of
    % shared variables is smaller than the number of argument variables of the 
    % call.
    % 
    % Succeed if it is worth parallelizing the two goals.
    % Fail otherwise.
    %
:- pred is_worth_parallelizing(hlds_goal::in, hlds_goal::in, proc_info::in, 
    module_info::in) is semidet.

is_worth_parallelizing(GoalA, GoalB, ProcInfo, ModuleInfo) :-
    proc_info_get_initial_instmap(ProcInfo, ModuleInfo, InstMap),
    SharedVars = find_shared_variables(ModuleInfo, InstMap, [ GoalA, GoalB ]),
    set.to_sorted_list(SharedVars, SharedVarsList),
    list.length(SharedVarsList, NbSharedVars),
    ( NbSharedVars = 0 ->
        % No shared vars between the goals.
        true
    ;
        ( goal_is_conjunction(GoalB, parallel_conj) ->
            get_number_args(GoalA, NbArgsA),
            NbSharedVars < NbArgsA 
        ;
            (
                get_number_args(GoalA, NbArgsA),
                get_number_args(GoalB, NbArgsB) 
            ->
                ( NbSharedVars < NbArgsA, NbSharedVars < NbArgsB
                ; NbSharedVars = NbArgsA, NbSharedVars < NbArgsB
                ; NbSharedVars < NbArgsA, NbSharedVars = NbArgsB
                ) 
            ;
                unexpected(this_file, "is_worth_parallelizing")
            )
        )
    ).

    % Give the number of argument variables of a call.
    %
:- pred get_number_args(hlds_goal::in, int::out) is semidet.

get_number_args(Call, NbArgs) :-
    CallExpr = Call ^ hlds_goal_expr,
    (
        CallExpr = plain_call(_, _, Args, _, _, _),
        list.length(Args, NbArgs)
    ;
        CallExpr = generic_call(Details, Args, _, _),
        (
            Details = higher_order(_, _, _, _),
            list.length(Args, NbArgs)
        ;
            Details = class_method(_, _, _, _),
            list.length(Args, NbArgs)
        )
    ;
        CallExpr = call_foreign_proc(_, _, _, Args, _, _, _),
        list.length(Args, NbArgs)
    ).

    % Add a call to an existing parallel conjunction.
    %
:- pred add_call_to_parallel_conjunction(hlds_goal::in, hlds_goal::in,
    hlds_goal::out) is det.

add_call_to_parallel_conjunction(Call, ParallelGoal0, ParallelGoal) :-
    ParallelGoalExpr0 = ParallelGoal0 ^ hlds_goal_expr,
    ParallelGoalInfo0 = ParallelGoal0 ^ hlds_goal_info,
    ( ParallelGoalExpr0 = conj(parallel_conj, GoalList0) ->
        GoalList = [ Call | GoalList0 ],
        goal_list_nonlocals(GoalList, NonLocals),
        goal_list_instmap_delta(GoalList, InstMapDelta),
        goal_list_determinism(GoalList, Detism),
        goal_list_purity(GoalList, Purity), 
        goal_info_set_nonlocals(NonLocals, ParallelGoalInfo0, 
            ParallelGoalInfo1),
        goal_info_set_instmap_delta(InstMapDelta, ParallelGoalInfo1, 
            ParallelGoalInfo2),
        goal_info_set_determinism(Detism, ParallelGoalInfo2, ParallelGoalInfo3),
        goal_info_set_purity(Purity, ParallelGoalInfo3, ParallelGoalInfo),
        ParallelGoalExpr = conj(parallel_conj, GoalList),
        ParallelGoal = hlds_goal(ParallelGoalExpr, ParallelGoalInfo)
    ;
        unexpected(this_file, "add_call_to_parallel_conjunction")
    ).

    % Succeed if the first goal depends on the second one.
    % Fail otherwise.
    %
:- pred goal_depends_on_goal(hlds_goal::in, hlds_goal::in) is semidet.

goal_depends_on_goal(hlds_goal(_, GoalInfo1), hlds_goal(_, GoalInfo2)) :-
    goal_info_get_instmap_delta(GoalInfo1, InstmapDelta1),
    instmap_delta_changed_vars(InstmapDelta1, ChangedVars1),
    goal_info_get_nonlocals(GoalInfo2, NonLocals2),
    set.intersect(ChangedVars1, NonLocals2, Intersection),
    \+ set.empty(Intersection).

    % Process a conjunction for implicit parallelism.
    %
:- pred process_conj_for_implicit_parallelism(
    hlds_goal_expr::in, hlds_goal_expr::out, int::in, 
    proc_info::in, module_info::in, module_info::out,
    list(candidate_call_site)::in, list(candidate_call_site)::out,
    counter::in, counter::out) is det.

process_conj_for_implicit_parallelism(!GoalExpr, IndexInConj, ProcInfo, 
    !ModuleInfo, !CalleeListToBeParallelized, !SiteNumCounter) :-
    ( !.GoalExpr = conj(_, GoalsConj) ->
        list.length(GoalsConj, Length),
        ( IndexInConj > Length ->
            true
        ;
            MaybeConj0 = yes(!.GoalExpr),
            list.index1_det(GoalsConj, IndexInConj, GoalInConj),
            % We are not interested in the return value of GoalInConj, only 
            % MaybeConj matters.
            process_goal_for_implicit_parallelism(GoalInConj, _, ProcInfo, 
                !ModuleInfo, MaybeConj0, MaybeConj, IndexInConj, IndexInConj0, 
                !CalleeListToBeParallelized, !SiteNumCounter),
            ( MaybeConj = yes(GoalExprProcessed) ->
                !:GoalExpr = GoalExprProcessed
            ;
                unexpected(this_file, "process_conj_for_implicit_parallelism")
            ),
            process_conj_for_implicit_parallelism(!GoalExpr, IndexInConj0, 
                ProcInfo, !ModuleInfo, !CalleeListToBeParallelized, 
                !SiteNumCounter)
        )
    ;
        unexpected(this_file, "process_conj_for_implicit_parallelism")
    ).

    % Process a disjunction for implicit parallelism.
    %
:- pred process_disj_for_implicit_parallelism(
    list(hlds_goal)::in, list(hlds_goal)::in, list(hlds_goal)::out, 
    proc_info::in, module_info::in, module_info::out,
    list(candidate_call_site)::in, list(candidate_call_site)::out,
    counter::in, counter::out) is det.

process_disj_for_implicit_parallelism([], !GoalsAcc, _ProcInfo,
        !ModuleInfo, !CalleeListToBeParallelized, !SiteNumCounter).
process_disj_for_implicit_parallelism([ Goal0 | Goals ], !GoalsAcc, 
        ProcInfo, !ModuleInfo, !CalleeListToBeParallelized, !SiteNumCounter) :-
    process_goal_for_implicit_parallelism(Goal0, Goal, ProcInfo, 
        !ModuleInfo, no, _, 0, _, !CalleeListToBeParallelized, !SiteNumCounter),
    list.append(!.GoalsAcc, [ Goal ], !:GoalsAcc),
    process_disj_for_implicit_parallelism(Goals, !GoalsAcc, ProcInfo, 
        !ModuleInfo, !CalleeListToBeParallelized, !SiteNumCounter).

    % If we are in a conjunction, update it by replacing the goal at index by 
    % Goal and increment the index.
    %
:- pred update_conj_and_index(
    maybe(hlds_goal_expr)::in, maybe(hlds_goal_expr)::out, 
    hlds_goal::in, int::in, int::out) is det.

update_conj_and_index(!MaybeConj, Goal, !IndexInConj) :-
    ( !.MaybeConj = yes(conj(Type, Goals0)) -> 
        list.replace_nth_det(Goals0, !.IndexInConj, Goal, Goals),
        !:IndexInConj = !.IndexInConj + 1,
        !:MaybeConj = yes(conj(Type, Goals))
    ;
        true
    ).

    % Process a switch for implicit parallelism.
    %
:- pred process_switch_cases_for_implicit_parallelism(
    list(case)::in, list(case)::in, list(case)::out, proc_info::in,
    module_info::in, module_info::out,
    list(candidate_call_site)::in, list(candidate_call_site)::out, 
    counter::in, counter::out) is det.

process_switch_cases_for_implicit_parallelism([], !CasesAcc, _ProcInfo,
        !ModuleInfo, !CalleeListToBeParallelized, !SiteNumCounter).
process_switch_cases_for_implicit_parallelism([ Case0 | Cases ], !CasesAcc, 
        ProcInfo, !ModuleInfo, !CalleeListToBeParallelized, !SiteNumCounter) :-
    Case0 = case(Functor, Goal0), 
    process_goal_for_implicit_parallelism(Goal0, Goal, ProcInfo, 
        !ModuleInfo, no, _, 0, _, !CalleeListToBeParallelized, !SiteNumCounter),
    list.append(!.CasesAcc, [ case(Functor, Goal) ], !:CasesAcc),
    process_switch_cases_for_implicit_parallelism(Cases, !CasesAcc, 
        ProcInfo, !ModuleInfo, !CalleeListToBeParallelized, !SiteNumCounter).

%-----------------------------------------------------------------------------%

    % Parse the feedback file (header and body).
    %
:- pred parse_feedback_file(string::in, 
    maybe_error(list(candidate_call_site))::out, io::di, io::uo) is det.

parse_feedback_file(InputFile, MaybeListCandidateCallSite, !IO) :-
    io.open_input(InputFile, Result, !IO),
    (
        Result = io.error(ErrInput),
        MaybeListCandidateCallSite = error(io.error_message(ErrInput))
    ;
        Result = ok(Stream),
        io.read_file_as_string(Stream, MaybeFileAsString, !IO),
        (
            MaybeFileAsString = ok(FileAsString),
            LineList = string.words_separator(is_carriage_return, 
                FileAsString),
            process_header(LineList, MaybeBodyFileAsListString, !IO),
            (
                MaybeBodyFileAsListString = error(ErrProcessHeader),
                MaybeListCandidateCallSite = error(ErrProcessHeader)
            ;
                MaybeBodyFileAsListString = ok(BodyFileAsListString),
                process_body(BodyFileAsListString, MaybeListCandidateCallSite)
            )
        ;
            MaybeFileAsString = error(_, ErrReadFileAsString),
            MaybeListCandidateCallSite = 
                error(io.error_message(ErrReadFileAsString))
        ),
        io.close_input(Stream, !IO)
    ).

:- pred is_carriage_return(char::in) is semidet.

is_carriage_return(Char) :-
    Char = '\n'.

    % Process the header of the feedback file.
    %
:- pred process_header(list(string)::in, maybe_error(list(string))::out, 
    io::di, io::uo) is det.

process_header(FileAsListString, MaybeFileAsListStringWithoutHeader, !IO) :-
    ( list.index0(FileAsListString, 0, Type) ->
        ( Type = "Profiling feedback file" ->
            (list.index0(FileAsListString, 1, Version) ->
                ( Version = "Version = 1.0" ->
                    list.det_split_list(4, FileAsListString, _, 
                        FileAsListStringWithoutHeader),
                    MaybeFileAsListStringWithoutHeader = 
                        ok(FileAsListStringWithoutHeader)
                ;
                    MaybeFileAsListStringWithoutHeader = error("Profiling" ++ 
                    " feedback file version incorrect")
                )
            ;
                MaybeFileAsListStringWithoutHeader = error("Not a profiling" 
                ++ " feedback file")
            )
        ;
            MaybeFileAsListStringWithoutHeader = error("Not a profiling" ++ 
                " feedback file")
        )
    ;
        MaybeFileAsListStringWithoutHeader = error("Not a profiling feedback"
            ++ " file")
    ).

    % Process the body of the feedback file.
    %
:- pred process_body(list(string)::in, 
    maybe_error(list(candidate_call_site))::out) is det.

process_body(CoreFileAsListString, MaybeListCandidateCallSite) :-
    ( process_body2(CoreFileAsListString, [], ListCandidateCallSite) ->
        MaybeListCandidateCallSite = ok(ListCandidateCallSite)
    ;
        MaybeListCandidateCallSite = error("Profiling feedback file is not" 
            ++ " well-formed")
    ).

:- pred process_body2(list(string)::in, list(candidate_call_site)::in, 
    list(candidate_call_site)::out) is semidet.

process_body2([], !ListCandidateCallSiteAcc).
process_body2([ Line | Lines ], !ListCandidateCallSiteAcc) :-
    Words = string.words_separator(is_whitespace, Line),
    list.index0_det(Words, 0, Caller),
    ( Caller = "Mercury" ->
        process_body2(Lines, !ListCandidateCallSiteAcc)
    ;
        list.index0_det(Words, 1, SlotNumber),
        string.to_int(SlotNumber, IntSlotNumber),
        list.index0_det(Words, 2, KindAsString),
        ( construct_call_site_kind(KindAsString, Kind) ->
            ( Kind = csk_normal ->
                list.index0_det(Words, 3, Callee),
                CandidateCallSite = candidate_call_site(Caller, IntSlotNumber,
                    Kind, Callee)
            ;
                CandidateCallSite = candidate_call_site(Caller, IntSlotNumber,
                    Kind, "")
            )
        ;
            % Unexpected call site kind.
            unexpected(this_file, "process_body2")
        ),
        !:ListCandidateCallSiteAcc = [ CandidateCallSite | 
            !.ListCandidateCallSiteAcc ],
        process_body2(Lines, !ListCandidateCallSiteAcc)
    ).

%-----------------------------------------------------------------------------%

:- func this_file = string.

this_file = "implicit_parallelism.m".

%-----------------------------------------------------------------------------%
:- end_module transform_hlds.implicit_parallelism.
%-----------------------------------------------------------------------------%
