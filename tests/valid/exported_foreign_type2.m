:- module exported_foreign_type2.
:- interface.

:- type t ---> t(int).
:- pragma foreign_type("C", t, "int") where equality is int_equals, comparison is int_compare.

:- pred int_equals(t::in, t::in) is semidet.
:- pred int_compare(comparison_result::uo, t::in, t::in) is det.

:- implementation.
:- import_module int.

:- pragma foreign_proc("C", int_equals(T1::in, T2::in), [promise_pure],
"SUCCESS_INDICATOR = (T1 == T2);").

int_compare((Res < 0 -> (<) ; Res = 0 -> (=) ; (>)), T1, T2) :-
	int_compare_2(Res, T1, T2).

:- pred int_compare_2(int::out, t::in, t::in) is det.

:- pragma foreign_proc("C",
	int_compare_2(Result::out, T1::in, T2::in), [promise_pure],
"Result = (T1 < T2) ? -1 : ((T1 == T2) ? 0 : 1);").

