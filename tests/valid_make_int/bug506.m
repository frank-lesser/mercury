%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%

:- module bug506.
:- interface.

:- import_module bug506_sub.

:- func make_rule(int) = (rule).

:- implementation.

make_rule(N) = rule(N).
