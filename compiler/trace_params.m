%-----------------------------------------------------------------------------%
% Copyright (C) 2000-2004 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: trace_params.m.
%
% Author: zs.
%
% This module defines the parameters of execution tracing at various trace
% levels and with various settings of the --suppress-trace option.
%
% In most cases the trace level we want to apply to a procedure (which is its
% effective trace level) is the same as the global trace level. However, if the
% global trace level is shallow, then we optimize the handling of procedures
% that cannot be called from deep traced contexts. If a procedure is neither
% exported nor has its address taken, then it can only be called from other
% procedures in its module. If the module is shallow traced, this guarantees
% that we will never get any events from the procedure, so there is no point
% in including any tracing code in it in the first place. We therefore make
% its effective trace level "none" for must purposes (the purposes whose
% functions test effective trace levels). Apart from avoiding the overhead
% of calls to MR_trace, this also allows the code generator to preserve tail
% recursion optimization. However, we continue to generate the data structures
% that enable the debugger to walk the stack for such procedures. We accomplish
% this by making the relevant test work on the global trace level, not
% effective trace levels. Most of the other functions defined in this module
% convert the given (global) trace level into the effective trace level of
% the relevant procedure before calculating their result.

%-----------------------------------------------------------------------------%

:- module libs__trace_params.

:- interface.

:- import_module hlds.
:- import_module hlds__hlds_pred.

:- import_module bool, std_util.

:- type trace_level.
:- type trace_suppress_items.

	% The kinds of events with which MR_trace may be called, either
	% by compiler-generated code, or by code in the standard library
	% referring to compiler-generated data structures.
:- type trace_port
	--->	call
	;	exit
	;	fail
	;	redo
	;	exception
	;	ite_cond
	;	ite_then
	;	ite_else
	;	neg_enter
	;	neg_success
	;	neg_failure
	;	switch
	;	disj
	;	nondet_pragma_first
	;	nondet_pragma_later.

	% The string should be the value of the --trace-level option;
	% two bools should be the values of the `--require-tracing' and
	% `--decl-debug' grade options.
	%
	% If the string is an acceptable trace level in the specified kinds of
	% grades, return yes wrapper around the trace level.
	%
	% If the string is an known trace level that happens not to be
	% acceptable in the specified kinds of grades, return no.
	%
	% If the string is not known trace level, fail.
:- pred convert_trace_level(string::in, bool::in, bool::in,
	maybe(trace_level)::out) is semidet.

:- pred convert_trace_suppress(string::in, trace_suppress_items::out)
	is semidet.
:- func default_trace_suppress = trace_suppress_items.

	% These functions check for various properties of the global
	% trace level.
:- func given_trace_level_is_none(trace_level) = bool.
:- func trace_level_allows_delay_death(trace_level) = bool.
:- func trace_needs_return_info(trace_level, trace_suppress_items) = bool.

	% Should optimization passes maintain meaningful
	% variable names where possible.
:- func trace_level_needs_meaningful_var_names(trace_level) = bool.

	% These functions check for various properties of the given procedure's
	% effective trace level.
:- func eff_trace_level_is_none(pred_info, proc_info, trace_level) = bool.
:- func eff_trace_level_needs_input_vars(pred_info, proc_info, trace_level)
	= bool.
:- func eff_trace_level_needs_fixed_slots(pred_info, proc_info, trace_level)
	= bool.
:- func eff_trace_level_needs_from_full_slot(pred_info, proc_info, trace_level)
	= bool.
:- func eff_trace_needs_all_var_names(pred_info, proc_info, trace_level,
	trace_suppress_items) = bool.
:- func eff_trace_needs_proc_body_reps(pred_info, proc_info, trace_level,
	trace_suppress_items) = bool.
:- func eff_trace_needs_port(pred_info, proc_info, trace_level,
	trace_suppress_items, trace_port) = bool.

:- func eff_trace_level(pred_info, proc_info, trace_level) = trace_level.

:- func trace_level_none = trace_level.

	% Given a trace level for a module, return the trace level we should
	% use for compiler-generated unify, index and compare predicates.
:- func trace_level_for_unify_compare(trace_level) = trace_level.

	% This is used to represent the trace level in the module layout
	% and in proc layouts.
:- func trace_level_rep(trace_level) = string.

:- func encode_suppressed_events(trace_suppress_items) = int.

:- implementation.

:- import_module hlds__special_pred.

:- import_module int, char, string, list, set.

:- type trace_level
	--->	none
	;	shallow
	;	deep
	;	decl_rep.

:- type trace_suppress_item
	--->	port(trace_port)
	;	return_info
	;	all_var_names
	;	proc_body_reps.

:- type trace_suppress_items == set(trace_suppress_item).

trace_level_none = none.

trace_level_for_unify_compare(none) = none.
trace_level_for_unify_compare(shallow) = shallow.
trace_level_for_unify_compare(deep) = shallow.
trace_level_for_unify_compare(decl_rep) = shallow.

convert_trace_level("minimum", no,  no,  yes(none)).
convert_trace_level("minimum", yes, no,  yes(shallow)).
convert_trace_level("minimum", _,   yes, yes(deep)).
convert_trace_level("shallow", _,   no,  yes(shallow)).
convert_trace_level("shallow", _,   yes, no).
convert_trace_level("deep",    _,   no,  yes(deep)).
convert_trace_level("deep",    _,   yes, no).
convert_trace_level("decl",    _,   _,   yes(deep)).
convert_trace_level("rep",     _,   _,   yes(decl_rep)).
convert_trace_level("default", no,  no,  yes(none)).
convert_trace_level("default", yes, no,  yes(deep)).
convert_trace_level("default", _,   yes, yes(deep)).

eff_trace_level(PredInfo, ProcInfo, TraceLevel) = EffTraceLevel :-
	(
		TraceLevel = shallow,
		pred_info_import_status(PredInfo, Status),
		status_is_exported(Status, no),
		proc_info_is_address_taken(ProcInfo, address_is_not_taken),
		pred_info_get_maybe_special_pred(PredInfo, MaybeSpecialPred),
			% Unify and compare predicates can be called from
			% the generic unify and compare predicates in
			% builtin.m, so they can be called from outside this
			% module even if they don't have their address taken.
		(
			MaybeSpecialPred = no
		;
			MaybeSpecialPred = yes(index - _)
		)
	->
		EffTraceLevel = none
	;
		EffTraceLevel = TraceLevel
	).

given_trace_level_is_none(TraceLevel) =
	trace_level_is_none(TraceLevel).

eff_trace_level_is_none(PredInfo, ProcInfo, TraceLevel) =
	trace_level_is_none(
		eff_trace_level(PredInfo, ProcInfo, TraceLevel)).
eff_trace_level_needs_input_vars(PredInfo, ProcInfo, TraceLevel) =
	trace_level_needs_input_vars(
		eff_trace_level(PredInfo, ProcInfo, TraceLevel)).
eff_trace_level_needs_fixed_slots(PredInfo, ProcInfo, TraceLevel) =
	trace_level_needs_fixed_slots(
		eff_trace_level(PredInfo, ProcInfo, TraceLevel)).
eff_trace_level_needs_from_full_slot(PredInfo, ProcInfo, TraceLevel) =
	trace_level_needs_from_full_slot(
		eff_trace_level(PredInfo, ProcInfo, TraceLevel)).
eff_trace_needs_all_var_names(PredInfo, ProcInfo, TraceLevel, SuppressItems) =
	trace_needs_all_var_names(
		eff_trace_level(PredInfo, ProcInfo, TraceLevel),
		SuppressItems).
eff_trace_needs_proc_body_reps(PredInfo, ProcInfo, TraceLevel, SuppressItems) =
	trace_needs_proc_body_reps(
		eff_trace_level(PredInfo, ProcInfo, TraceLevel),
		SuppressItems).
eff_trace_needs_port(PredInfo, ProcInfo, TraceLevel, SuppressItems, Port) =
	trace_needs_port(eff_trace_level(PredInfo, ProcInfo, TraceLevel),
		SuppressItems, Port).

:- func trace_level_is_none(trace_level) = bool.
:- func trace_level_needs_input_vars(trace_level) = bool.
:- func trace_level_needs_fixed_slots(trace_level) = bool.
:- func trace_level_needs_from_full_slot(trace_level) = bool.
:- func trace_needs_all_var_names(trace_level, trace_suppress_items) = bool.
:- func trace_needs_proc_body_reps(trace_level, trace_suppress_items) = bool.
:- func trace_needs_port(trace_level, trace_suppress_items, trace_port) = bool.

trace_level_is_none(none) = yes.
trace_level_is_none(shallow) = no.
trace_level_is_none(deep) = no.
trace_level_is_none(decl_rep) = no.

trace_level_needs_input_vars(none) = no.
trace_level_needs_input_vars(shallow) = yes.
trace_level_needs_input_vars(deep) = yes.
trace_level_needs_input_vars(decl_rep) = yes.

trace_level_needs_fixed_slots(none) = no.
trace_level_needs_fixed_slots(shallow) = yes.
trace_level_needs_fixed_slots(deep) = yes.
trace_level_needs_fixed_slots(decl_rep) = yes.

trace_level_needs_from_full_slot(none) = no.
trace_level_needs_from_full_slot(shallow) = yes.
trace_level_needs_from_full_slot(deep) = no.
trace_level_needs_from_full_slot(decl_rep) = no.

trace_level_allows_delay_death(none) = no.
trace_level_allows_delay_death(shallow) = no.
trace_level_allows_delay_death(deep) = yes.
trace_level_allows_delay_death(decl_rep) = yes.

trace_level_needs_meaningful_var_names(none) = no.
trace_level_needs_meaningful_var_names(shallow) = no.
trace_level_needs_meaningful_var_names(deep) = yes.
trace_level_needs_meaningful_var_names(decl_rep) = yes.

trace_needs_return_info(TraceLevel, TraceSuppressItems) = Need :-
	(
		trace_level_has_return_info(TraceLevel) = yes,
		\+ set__member(return_info, TraceSuppressItems)
	->
		Need = yes
	;
		Need = no
	).

trace_needs_all_var_names(TraceLevel, TraceSuppressItems) = Need :-
	(
		trace_level_has_all_var_names(TraceLevel) = yes,
		\+ set__member(all_var_names, TraceSuppressItems)
	->
		Need = yes
	;
		Need = no
	).

trace_needs_proc_body_reps(TraceLevel, TraceSuppressItems) = Need :-
	(
		trace_level_has_proc_body_reps(TraceLevel) = yes,
		\+ set__member(proc_body_reps, TraceSuppressItems)
	->
		Need = yes
	;
		Need = no
	).

:- func trace_level_has_return_info(trace_level) = bool.
:- func trace_level_has_all_var_names(trace_level) = bool.
:- func trace_level_has_proc_body_reps(trace_level) = bool.

trace_level_has_return_info(none) = no.
trace_level_has_return_info(shallow) = yes.
trace_level_has_return_info(deep) = yes.
trace_level_has_return_info(decl_rep) = yes.

trace_level_has_all_var_names(none) = no.
trace_level_has_all_var_names(shallow) = no.
trace_level_has_all_var_names(deep) = no.
trace_level_has_all_var_names(decl_rep) = yes.

trace_level_has_proc_body_reps(none) = no.
trace_level_has_proc_body_reps(shallow) = no.
trace_level_has_proc_body_reps(deep) = no.
trace_level_has_proc_body_reps(decl_rep) = yes.

convert_trace_suppress(SuppressString, SuppressItemSet) :-
	SuppressWords = string__words(char_is_comma, SuppressString),
	list__map(convert_item_name, SuppressWords, SuppressItemLists),
	list__condense(SuppressItemLists, SuppressItems),
	set__list_to_set(SuppressItems, SuppressItemSet).

:- pred char_is_comma(char::in) is semidet.

char_is_comma(',').

default_trace_suppress = set__init.

:- func convert_port_name(string) = trace_port is semidet.

	% The call port cannot be disabled, because its layout structure is
	% referred to implicitly by the redo command in mdb.
	%
	% The exception port cannot be disabled, because it is never put into
	% compiler-generated code in the first place; such events are created
	% on the fly by library/exception.m.
% convert_port_name("call") = call.
convert_port_name("exit") = exit.
convert_port_name("fail") = fail.
convert_port_name("redo") = redo.
% convert_port_name("excp") = exception.
convert_port_name("exception") = exception.
convert_port_name("cond") = ite_cond.
convert_port_name("ite_cond") = ite_cond.
convert_port_name("then") = ite_then.
convert_port_name("ite_then") = ite_then.
convert_port_name("else") = ite_else.
convert_port_name("ite_else") = ite_else.
convert_port_name("nege") = neg_enter.
convert_port_name("neg_enter") = neg_enter.
convert_port_name("negs") = neg_success.
convert_port_name("neg_success") = neg_success.
convert_port_name("negf") = neg_failure.
convert_port_name("neg_failure") = neg_failure.
convert_port_name("swtc") = switch.
convert_port_name("switch") = switch.
convert_port_name("disj") = disj.
convert_port_name("frst") = nondet_pragma_first.
convert_port_name("nondet_pragma_first") = nondet_pragma_first.
convert_port_name("latr") = nondet_pragma_first.
convert_port_name("nondet_pragma_later") = nondet_pragma_later.

:- func convert_port_class_name(string) = list(trace_port) is semidet.

convert_port_class_name("interface") =
	[call, exit, redo, fail, exception].
convert_port_class_name("internal") =
	[ite_then, ite_else, switch, disj].
convert_port_class_name("context") =
	[ite_cond, neg_enter, neg_success, neg_failure].

:- func convert_other_name(string) = trace_suppress_item is semidet.

convert_other_name("return") = return_info.
convert_other_name("return_info") = return_info.
convert_other_name("names") = all_var_names.
convert_other_name("all_var_names") = all_var_names.
convert_other_name("bodies") = proc_body_reps.
convert_other_name("proc_body_reps") = proc_body_reps.

:- pred convert_item_name(string::in, list(trace_suppress_item)::out)
	is semidet.

convert_item_name(String, Names) :-
	( convert_port_name(String) = PortName ->
		Names = [port(PortName)]
	; convert_port_class_name(String) = PortNames ->
		list__map(wrap_port, PortNames, Names)
	; convert_other_name(String) = OtherName ->
		Names = [OtherName]
	;
		fail
	).

:- pred wrap_port(trace_port::in, trace_suppress_item::out) is det.

wrap_port(Port, port(Port)).

	% If this is modified, then the corresponding code in
	% runtime/mercury_stack_layout.h needs to be updated.
trace_level_rep(none)	  = "MR_TRACE_LEVEL_NONE".
trace_level_rep(shallow)  = "MR_TRACE_LEVEL_SHALLOW".
trace_level_rep(deep)	  = "MR_TRACE_LEVEL_DEEP".
trace_level_rep(decl_rep) = "MR_TRACE_LEVEL_DECL_REP".

%-----------------------------------------------------------------------------%

:- type port_category
	--->	interface	% The events that describe the interface of a
				% procedure with its callers.
	;	internal	% The events inside each procedure that were
				% present in the initial procedural debugger.
	;	context.	% The events inside each procedure that we
				% added because the declarative debugger needs
				% to know when (potentially) negated contexts
				% start and end.

:- func trace_port_category(trace_port) = port_category.

trace_port_category(call)			= interface.
trace_port_category(exit)			= interface.
trace_port_category(fail)			= interface.
trace_port_category(redo)			= interface.
trace_port_category(exception)			= interface.
trace_port_category(ite_cond)			= context.
trace_port_category(ite_then)			= internal.
trace_port_category(ite_else)			= internal.
trace_port_category(neg_enter)			= context.
trace_port_category(neg_success)		= context.
trace_port_category(neg_failure)		= context.
trace_port_category(switch)			= internal.
trace_port_category(disj)			= internal.
trace_port_category(nondet_pragma_first)	= internal.
trace_port_category(nondet_pragma_later)	= internal.

:- func trace_level_port_categories(trace_level) = list(port_category).

trace_level_port_categories(none) = [].
trace_level_port_categories(shallow) = [interface].
trace_level_port_categories(deep) = [interface, internal, context].
trace_level_port_categories(decl_rep) = [interface, internal, context].

:- func trace_level_allows_port_suppression(trace_level) = bool.

trace_level_allows_port_suppression(none) = no.		% no ports exist
trace_level_allows_port_suppression(shallow) = yes.
trace_level_allows_port_suppression(deep) = yes.
trace_level_allows_port_suppression(decl_rep) = no.

trace_needs_port(TraceLevel, TraceSuppressItems, Port) = NeedsPort :-
	(
		trace_port_category(Port) = Category,
		list__member(Category,
			trace_level_port_categories(TraceLevel)),
		\+ (
			trace_level_allows_port_suppression(TraceLevel) = yes,
			set__member(port(Port), TraceSuppressItems)
		)
	->
		NeedsPort = yes
	;
		NeedsPort = no
	).

encode_suppressed_events(SuppressedEvents) = SuppressedEventsInt :-
	set__fold(maybe_add_suppressed_event, SuppressedEvents,
		0, SuppressedEventsInt).

:- pred maybe_add_suppressed_event(trace_suppress_item::in, int::in, int::out)
	is det.

maybe_add_suppressed_event(SuppressItem, SuppressedEventsInt0,
		SuppressedEventsInt) :-
	( SuppressItem = port(Port) ->
		SuppressedEventsInt = SuppressedEventsInt0 \/
			(1 << port_number(Port))
	;
		SuppressedEventsInt = SuppressedEventsInt0
	).

:- func port_number(trace_port) = int.

port_number(call) = 1.
port_number(exit) = 2.
port_number(redo) = 3.
port_number(fail) = 4.
port_number(exception) = 5.
port_number(ite_cond) = 6.
port_number(ite_then) = 7.
port_number(ite_else) = 8.
port_number(neg_enter) = 9.
port_number(neg_success) = 10.
port_number(neg_failure) = 11.
port_number(disj) = 12.
port_number(switch) = 13.
port_number(nondet_pragma_first) = 14.
port_number(nondet_pragma_later) = 15.
