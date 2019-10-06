%---------------------------------------------------------------------------%
% vim: ts=4 sw=4 et ft=mercury
%---------------------------------------------------------------------------%

:- module bug485.
:- interface.

:- type dt
    --->    dummy_value.

%---------------------------------------------------------------------------%

:- implementation.

:- pragma foreign_enum("C", dt/0, [
    dummy_value - "42"
]).

%---------------------------------------------------------------------------%
