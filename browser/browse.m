%---------------------------------------------------------------------------%
% Copyright (C) 1998-2004 The University of Melbourne.
% This file may only be copied under the terms of the GNU Library General
% Public License - see the file COPYING.LIB in the Mercury distribution.
%---------------------------------------------------------------------------%

% browse - implements a very simple term browser.
% There are a number of features that haven't been incorporated:
%	- Scripting language that allows precise control over
%	  how types are printed.
%	- User preferences, which use the scripting language
%	  to allow user control beyond the provided defaults.
%	- Node expansion and contraction in the style of
%	  Windows Explorer.
%
% authors: aet
% stability: low

:- module mdb__browse.

:- interface.

:- import_module mdb__browser_info.
:- import_module io, bool, std_util, list.

	% The interactive term browser.  The caller type will be `browse', and
	% the default format for the `browse' caller type will be used.
	%
:- pred browse__browse(T::in, io__input_stream::in,
	io__output_stream::in, maybe(list(dir))::out,
	browser_persistent_state::in, browser_persistent_state::out,
	io::di, io::uo) is cc_multi.

	% As above, except that the supplied format will override the default.
	%
:- pred browse__browse_format(T::in, io__input_stream::in,
	io__output_stream::in, portray_format::in,
	browser_persistent_state::in, browser_persistent_state::out,
	io::di, io::uo) is cc_multi.

	% A version of browse__browse that works on synthetic terms
	% in the sense of browser_info:browser_term.
	%
:- pred browse__browse_synthetic(string::in, list(univ)::in, bool::in,
	io__input_stream::in, io__output_stream::in, maybe(list(dir))::out,
	browser_persistent_state::in, browser_persistent_state::out,
	io::di, io::uo) is cc_multi.

	% A version of browse__browse_format that works on synthetic terms
	% in the sense of browser_info:browser_term.
	%
:- pred browse__browse_format_synthetic(string::in, list(univ)::in, bool::in,
	io__input_stream::in, io__output_stream::in, portray_format::in,
	browser_persistent_state::in, browser_persistent_state::out,
	io::di, io::uo) is cc_multi.

	% The browser interface for the external debugger.  The caller type
	% will be `browse', and the default format will be used.
	%
:- pred browse__browse_external(T::in, io__input_stream::in,
	io__output_stream::in,
	browser_persistent_state::in, browser_persistent_state::out,
	io::di, io::uo) is cc_multi.

	% The non-interactive term browser.  The caller type should be either
	% `print' or `print_all'.  The default portray format for that
	% caller type is used.
	%
:- pred browse__print(T::in, io__output_stream::in, browse_caller_type::in,
	browser_persistent_state::in, io::di, io::uo) is cc_multi.

	% A version of browse__print that works on synthetic terms
	% in the sense of browser_info:browser_term.
	%
:- pred browse__print_synthetic(string::in, list(univ)::in, bool::in,
	io__output_stream::in, browse_caller_type::in,
	browser_persistent_state::in, io::di, io::uo) is cc_multi.

	% As above, except that the supplied format will override the default.
	%
:- pred browse__print_format(T::in, io__output_stream::in,
	browse_caller_type::in, portray_format::in,
	browser_persistent_state::in, io::di, io::uo) is cc_multi.

	% A version of browse__print_format that works on synthetic terms
	% in the sense of browser_info:browser_term.
	%
:- pred browse__print_format_synthetic(string::in, list(univ)::in, bool::in,
	io__output_stream::in, browse_caller_type::in, portray_format::in,
	browser_persistent_state::in, io::di, io::uo) is cc_multi.

	% Estimate the total term size, in characters,
	% We count the number of characters in the functor,
	% plus two characters for each argument: "(" and ")"
	% for the first, and ", " for each of the rest,
	% plus the sizes of the arguments themselves.
	% This is only approximate since it doesn't take into
	% account all the special cases such as operators.
	%
	% This predicate returns not the estimated total term size,
	% but the difference between the given maximum size the caller
	% is interested in and the estimated total term size.
	% This difference is positive if the term is smaller than the
	% maximum and negative if it is bigger. If the difference is
	% negative, term_size_left_from_max will return a negative difference
	% but the value will usually not be accurate, since in such cases
	% by definition the caller is not interested in the accurate value.
:- pred term_size_left_from_max(univ::in, int::in, int::out) is cc_multi.

:- pred browser_term_size_left_from_max(browser_term::in,
	int::in, int::out) is cc_multi.

%---------------------------------------------------------------------------%

	% This predicate converts terms represented as univs to browser terms.

:- pred univ_to_browser_term(univ::in, browser_term::out) is det.

	% This predicate converts plain terms from the representation used
	% in the trace directory to browser terms.

:- pred plain_term_to_browser_term(T::in, browser_term::out) is det.

	% This predicate converts synthetic terms from the representation used
	% in the trace directory (as a list of arguments, the last of which
	% represents the return value for function calls) to the representation
	% used in the browser directory, in which a function call's return
	% value is stored separately from the other arguments.
	%
	% The reason why the trace directory does not use the latter
	% representation is that it would require C code to construct values
	% of type maybe(T).

:- pred synthetic_term_to_browser_term(string::in, list(univ)::in, bool::in,
	browser_term::out) is det.

	% save_term_to_file(FileName, Format, BrowserTerm, Out, !IO):
	% Save BrowserTerm to the file FileName. If there is an error,
	% print an error message to Out.
	%
	% The format of the saved term can be influenced by the Format
	% argument, but how this works is not specified.

:- pred save_term_to_file(string::in, string::in, browser_term::in,
	io__output_stream::in, io::di, io::uo) is cc_multi.

%---------------------------------------------------------------------------%

:- implementation.

:- import_module mdb__parse.
:- import_module mdb__util.
:- import_module mdb__frame.
:- import_module mdb__sized_pretty.

:- import_module string, int, char, map, std_util.
:- import_module parser, require, pprint, getopt, deconstruct.

%---------------------------------------------------------------------------%
%
% We export these predicates to C for use by the tracer:
% they are used in trace/mercury_trace_browser.c.
%

:- pragma export(browse__browse(in, in, in, out, in, out, di, uo),
	"ML_BROWSE_browse").
:- pragma export(browse__browse_format(in, in, in, in, in, out, di, uo),
	"ML_BROWSE_browse_format").
:- pragma export(browse__browse_synthetic(in, in, in, in, in, out,
	in, out, di, uo), "ML_BROWSE_browse_synthetic").
:- pragma export(browse__browse_format_synthetic(in, in, in, in, in, in,
	in, out, di, uo), "ML_BROWSE_browse_format_synthetic").
:- pragma export(browse__browse_external(in, in, in, in, out, di, uo),
	"ML_BROWSE_browse_external").
:- pragma export(browse__print(in, in, in, in, di, uo),
	"ML_BROWSE_print").
:- pragma export(browse__print_format(in, in, in, in, in, di, uo),
	"ML_BROWSE_print_format").
:- pragma export(browse__print_synthetic(in, in, in, in, in, in, di, uo),
	"ML_BROWSE_print_synthetic").
:- pragma export(browse__print_format_synthetic(in, in, in, in, in, in, in,
	di, uo), "ML_BROWSE_print_format_synthetic").

:- pragma export(plain_term_to_browser_term(in, out),
	"ML_BROWSE_plain_term_to_browser_term").
:- pragma export(univ_to_browser_term(in, out),
	"ML_BROWSE_univ_to_browser_term").
:- pragma export(synthetic_term_to_browser_term(in, in, in, out),
	"ML_BROWSE_synthetic_term_to_browser_term").
:- pragma export(save_term_to_file(in, in, in, in, di, uo),
	"ML_BROWSE_save_term_to_file").

%---------------------------------------------------------------------------%
%
% If the term browser is called from the internal debugger, input is
% done via a call to the readline library (if available), using streams
% MR_mdb_in and MR_mdb_out.  If it is called from the external debugger,
% Input/Output are done via MR_debugger_socket_in/MR_debugger_socket_out.
% In the latter case we need to output terms; their type is
% term_browser_response.

:- type term_browser_response
	--->	browser_str(string)
	;	browser_int(int)
	;	browser_nl
	;	browser_end_command
	;	browser_quit.

:- type debugger
	--->	internal
	;	external.

%---------------------------------------------------------------------------%
%
% Saving terms to files
%

save_term_to_file(FileName, _Format, BrowserTerm, OutStream, !IO) :-
	% io__write_string(FileName, !IO),
	% io__nl(!IO),
	% io__write(BrowserTerm, !IO),
	% io__nl(!IO),
	io__tell(FileName, FileStreamRes, !IO),
	(
		FileStreamRes = ok,
		(
			BrowserTerm = plain_term(Term),
			save_univ(0, Term, !IO),
			io__nl(!IO)
		;
			BrowserTerm = synthetic_term(Functor, Args, MaybeRes),
			io__write_string(Functor, !IO),
			io__write_string("(\n", !IO),
			save_args(1, Args, !IO),
			io__write_string("\n)\n", !IO),
			(
				MaybeRes = no
			;
				MaybeRes = yes(Result),
				io__write_string("=\n", !IO),
				save_univ(1, Result, !IO),
				io__write_string("\n", !IO)
			)
		),
		io__told(!IO)
	;
		FileStreamRes = error(Error),
		io__error_message(Error, Msg),
		io__write_string(OutStream, Msg, !IO)
	).

:- pred save_univ(int::in, univ::in, io::di, io::uo) is cc_multi.

save_univ(Indent, Univ, !IO) :-
	save_term(Indent, univ_value(Univ), !IO).

:- pred save_term(int::in, T::in, io::di, io::uo) is cc_multi.

save_term(Indent, Term, !IO) :-
	( dynamic_cast_to_list(Term, List) ->
		(
			List = [],
			write_indent(Indent, !IO),
			io__write_string("[]", !IO)
		;
			List = [_ | _],
			MakeUniv = (func(Element) = (ElementUniv) :-
				ElementUniv = univ(Element)
			),
			Univs = list__map(MakeUniv, List),
			write_indent(Indent, !IO),
			io__write_string("[\n", !IO),
			save_args(Indent + 1, Univs, !IO),
			io__write_string("\n", !IO),
			write_indent(Indent, !IO),
			io__write_string("]", !IO)
		)
	;
		deconstruct_cc(Term, Functor, _Arity, Args),
		write_indent(Indent, !IO),
		io__write_string(Functor, !IO),
		(
			Args = []
		;
			Args = [_ | _],
			io__write_string("(\n", !IO),
			save_args(Indent + 1, Args, !IO),
			io__write_string("\n", !IO),
			write_indent(Indent, !IO),
			io__write_string(")", !IO)
		)
	).

:- some [T2] pred dynamic_cast_to_list(T1::in, list(T2)::out) is semidet.

dynamic_cast_to_list(X, L) :-
	% The code of this predicate is copied from pprint.m.
	[ArgTypeDesc] = type_args(type_of(X)),
	(_ `with_type` ArgType) `has_type` ArgTypeDesc,
	dynamic_cast(X, L `with_type` list(ArgType)).

:- pred save_args(int::in, list(univ)::in, io::di, io::uo) is cc_multi.

save_args(_Indent, [], !IO).
save_args(Indent, [Univ | Univs], !IO) :-
	save_univ(Indent, Univ, !IO),
	(
		Univs = []
	;
		Univs = [_ | _],
		io__write_string(",\n", !IO),
		save_args(Indent, Univs, !IO)
	).

:- pred write_indent(int::in, io::di, io::uo) is det.

write_indent(Indent, !IO) :-
	( Indent =< 0 ->
		true
	;
		io__write_char(' ', !IO),
		write_indent(Indent - 1, !IO)
	).

%---------------------------------------------------------------------------%
%
% Non-interactive display
%

browse__print(Term, OutputStream, Caller, State, !IO) :-
	browse__print_common(plain_term(univ(Term)), OutputStream,
		Caller, no, State, !IO).

browse__print_format(Term, OutputStream, Caller, Format, State, !IO):-
	browse__print_common(plain_term(univ(Term)), OutputStream,
		Caller, yes(Format), State, !IO).

browse__print_synthetic(FunctorString, Args, IsFunc, OutputStream,
		Caller, State, !IO):-
	synthetic_term_to_browser_term(FunctorString, Args, IsFunc,
		BrowserTerm),
	browse__print_common(BrowserTerm, OutputStream, Caller, no, State,
		!IO).

browse__print_format_synthetic(FunctorString, Args, IsFunc, OutputStream,
		Caller, Format, State, !IO):-
	synthetic_term_to_browser_term(FunctorString, Args, IsFunc,
		BrowserTerm),
	browse__print_common(BrowserTerm, OutputStream,
		Caller, yes(Format), State, !IO).

:- pred browse__print_common(browser_term::in, io__output_stream::in,
	browse_caller_type::in, maybe(portray_format)::in,
	browser_persistent_state::in, io::di, io::uo) is cc_multi.

browse__print_common(BrowserTerm, OutputStream, Caller, MaybeFormat, State,
		!IO):-
	Info = browser_info__init(BrowserTerm, Caller, MaybeFormat, State),
	io__set_output_stream(OutputStream, OldStream, !IO),
	browser_info__get_format(Info, Caller, MaybeFormat, Format),
	%
	% For plain terms, we assume that the variable name has been printed
	% on the first part of the line.  If the format is something other than
	% `flat', then we need to start on the next line.
	%
	(
		BrowserTerm = plain_term(_),
		Format \= flat
	->
		io__nl(!IO)
	;
		true
	),
	portray(internal, Caller, no, Info, !IO),
	io__set_output_stream(OldStream, _, !IO).

%---------------------------------------------------------------------------%
%
% Interactive display
%

browse__browse(Object, InputStream, OutputStream, MaybeMark, !State, !IO) :-
	browse_common(internal, plain_term(univ(Object)),
		InputStream, OutputStream, no, MaybeMark, !State, !IO).

browse__browse_format(Object, InputStream, OutputStream, Format,
		!State, !IO) :-
	browse_common(internal, plain_term(univ(Object)),
		InputStream, OutputStream, yes(Format), _, !State, !IO).

browse__browse_synthetic(FunctorString, Args, IsFunc,
		InputStream, OutputStream, MaybeMark, !State, !IO) :-
	synthetic_term_to_browser_term(FunctorString, Args, IsFunc,
		BrowserTerm),
	browse_common(internal, BrowserTerm,
		InputStream, OutputStream, no, MaybeMark, !State, !IO).

browse__browse_format_synthetic(FunctorString, Args, IsFunc,
		InputStream, OutputStream, Format, !State, !IO) :-
	synthetic_term_to_browser_term(FunctorString, Args, IsFunc,
		BrowserTerm),
	browse_common(internal, BrowserTerm,
		InputStream, OutputStream, yes(Format), _, !State, !IO).

browse__browse_external(Object, InputStream, OutputStream, !State, !IO) :-
	browse_common(external, plain_term(univ(Object)),
		InputStream, OutputStream, no, _, !State, !IO).

:- pred browse_common(debugger::in, browser_term::in, io__input_stream::in,
	io__output_stream::in, maybe(portray_format)::in,
	maybe(list(dir))::out, browser_persistent_state::in,
	browser_persistent_state::out, io::di, io::uo) is cc_multi.

browse_common(Debugger, Object, InputStream, OutputStream, MaybeFormat,
		MaybeMark, !State, !IO) :-
	Info0 = browser_info__init(Object, browse, MaybeFormat, !.State),
	io__set_input_stream(InputStream, OldInputStream, !IO),
	io__set_output_stream(OutputStream, OldOutputStream, !IO),
	% startup_message,
	browse_main_loop(Debugger, Info0, Info, !IO),
	io__set_input_stream(OldInputStream, _, !IO),
	io__set_output_stream(OldOutputStream, _, !IO),
	MaybeMark = Info ^ maybe_mark,
	!:State = Info ^ state.

univ_to_browser_term(Univ, BrowserTerm) :-
	BrowserTerm = plain_term(Univ).

plain_term_to_browser_term(Term, BrowserTerm) :-
	BrowserTerm = plain_term(univ(Term)).

synthetic_term_to_browser_term(FunctorString, Args, IsFunc, BrowserTerm) :-
	(
		IsFunc = no,
		BrowserTerm = synthetic_term(FunctorString, Args, no)
	;
		IsFunc = yes,
		list__split_last_det(Args, FuncArgs, Return),
		BrowserTerm = synthetic_term(FunctorString, FuncArgs,
			yes(Return))
	).

:- pred browse_main_loop(debugger::in, browser_info::in, browser_info::out,
	io::di, io::uo) is cc_multi.

browse_main_loop(Debugger, !Info, !IO) :-
	(
		Debugger = internal,
		prompt(Prompt),
		parse__read_command(Prompt, Command, !IO)
	;
		Debugger = external,
		parse__read_command_external(Command, !IO)
	),
	run_command(Debugger, Command, Quit, !Info, !IO),
	(
		Quit = yes,
		% write_string_debugger(Debugger, "quitting...\n", !IO)
		(
			Debugger = external,
			send_term_to_socket(browser_quit, !IO)
		;
			Debugger = internal
		)
	;
		Quit = no,
		browse_main_loop(Debugger, !Info, !IO)
	).

:- pred startup_message(debugger::in, io::di, io::uo) is det.

startup_message(Debugger) -->
	write_string_debugger(Debugger, "-- Simple Mercury Term Browser.\n"),
	write_string_debugger(Debugger, "-- Type \"help\" for help.\n\n").

:- pred prompt(string::out) is det.

prompt("browser> ").

:- pred run_command(debugger::in, command::in, bool::out,
	browser_info::in, browser_info::out, io::di, io::uo) is cc_multi.

run_command(Debugger, Command, Quit, !Info, !IO) :-
	% XXX The commands `set', `ls' and `print' should allow the format
	% to be specified by an option.  In each case we instead pass `no' to
	% the respective handler.
	(
		Command = empty,
		Quit = no
	;
		Command = unknown,
		write_string_debugger(Debugger,
			"Error: unknown command or syntax error.\n", !IO),
		write_string_debugger(Debugger,
			"Type \"help\" for help.\n", !IO),
		Quit = no
	;
		Command = help,
		help(Debugger, !IO),
		Quit = no
	;
		Command = set,
		show_settings(Debugger, !.Info, !IO),
		Quit = no
	;
		Command = set(MaybeOptionTable, Setting),
		(
			MaybeOptionTable = ok(OptionTable),
			set_browse_param(OptionTable, Setting, !Info)
		;
			MaybeOptionTable = error(Msg),
			write_string_debugger(Debugger, Msg, !IO)
		),
		Quit = no
	;
		Command = cd,
		set_path(root_rel([]), !Info),
		Quit = no
	;
		Command = cd(Path),
		change_dir(!.Info ^ dirs, Path, NewPwd),
		deref_subterm(!.Info ^ term, NewPwd, [], Result),
		(
			Result = deref_result(_),
			!:Info = !.Info ^ dirs := NewPwd
		;
			Result = deref_error(OKPath, ErrorDir),
			report_deref_error(Debugger, OKPath, ErrorDir, !IO)
		),
		Quit = no
	;
		Command = print(PrintOption, MaybePath),
		do_portray(Debugger, browse, PrintOption, !.Info,
			MaybePath, !IO),
		Quit = no
	;
		Command = pwd,
		write_path(Debugger, !.Info ^ dirs, !IO),
		nl_debugger(Debugger, !IO),
		Quit = no
	;
		Command = mark,
		!:Info = !.Info ^ maybe_mark := yes(!.Info ^ dirs),
		Quit = yes
	;
		Command = mark(Path),
		change_dir(!.Info ^ dirs, Path, NewPwd),
		deref_subterm(!.Info ^ term, NewPwd, [], SubResult),
		(
			SubResult = deref_result(_),
			!:Info = !.Info ^ maybe_mark := yes(NewPwd),
			Quit = yes
		;
			SubResult = deref_error(_, _),
			write_string_debugger(Debugger,
				"error: cannot mark subterm\n", !IO),
			Quit = no
		)
	;
		Command = quit,
		Quit = yes
	;
		Command = display,
		write_string_debugger(Debugger,
			"command not yet implemented\n", !IO),
		Quit = no
	;
		Command = write,
		write_string_debugger(Debugger,
			"command not yet implemented\n", !IO),
		Quit = no
	),
	( Debugger = external ->
		send_term_to_socket(browser_end_command, !IO)
	;
		true
	).

:- pred do_portray(debugger::in, browse_caller_type::in,
	maybe(maybe_option_table(format_option))::in, browser_info::in,
	maybe(path)::in, io::di, io::uo) is cc_multi.

do_portray(Debugger, CallerType, MaybeMaybeOptionTable, Info,
		MaybePath, !IO) :-
	(
		MaybeMaybeOptionTable = no,
		portray_maybe_path(Debugger, CallerType, no, Info,
			MaybePath, !IO)
	;
		MaybeMaybeOptionTable = yes(MaybeOptionTable),
		(
			MaybeOptionTable = ok(OptionTable),
			interpret_format_options(OptionTable, FormatResult),
			(
				FormatResult = ok(MaybeFormat),
				portray_maybe_path(Debugger, CallerType,
					MaybeFormat, Info, MaybePath, !IO)
			;
				FormatResult = error(Msg),
				write_string_debugger(Debugger, Msg, !IO)
			)
		;
			MaybeOptionTable = error(Msg),
			write_string_debugger(Debugger, Msg, !IO)
		)
	).

:- pred interpret_format_options(option_table(format_option)::in,
	maybe_error(maybe(portray_format))::out) is det.

interpret_format_options(OptionTable, MaybeMaybeFormat) :-
	map__to_assoc_list(OptionTable, OptionAssocList),
	list__filter_map(bool_format_option_is_true, OptionAssocList,
		TrueFormatOptions),
	(
		TrueFormatOptions = [],
		MaybeMaybeFormat = ok(no)
	;
		TrueFormatOptions = [FormatOption],
		(
			FormatOption = flat,
			Format = flat
		;
			FormatOption = raw_pretty,
			Format = raw_pretty
		;
			FormatOption = pretty,
			Format = pretty
		;
			FormatOption = verbose,
			Format = verbose
		),
		MaybeMaybeFormat = ok(yes(Format))
	;
		TrueFormatOptions = [_, _ | _],
		MaybeMaybeFormat = error("error: inconsistent format options")
	).

:- pred bool_format_option_is_true(pair(format_option, option_data)::in,
	format_option::out) is semidet.

bool_format_option_is_true(Format - bool(yes), Format).

:- pred set_browse_param(option_table(setting_option)::in, setting::in,
	browser_info::in, browser_info::out) is det.

set_browse_param(OptionTable, Setting, Info0, Info) :-
	browser_info__set_param(yes,
		lookup_bool_option(OptionTable, print) `with_type` bool,
		lookup_bool_option(OptionTable, browse) `with_type` bool,
		lookup_bool_option(OptionTable, print_all) `with_type` bool,
		lookup_bool_option(OptionTable, flat) `with_type` bool,
		lookup_bool_option(OptionTable, raw_pretty) `with_type` bool,
		lookup_bool_option(OptionTable, verbose) `with_type` bool,
		lookup_bool_option(OptionTable, pretty) `with_type` bool,
		Setting, Info0 ^ state, NewState),
	Info = Info0 ^ state := NewState.

:- pred help(debugger::in, io::di, io::uo) is det.

help(Debugger) -->
	{ string__append_list([
"Commands are:\n",
"\t[print|p|ls] [format_options] [path]\n",
"\t               -- print the specified subterm using the `browse' params\n",
"\tcd [path]      -- cd to the specified subterm (default is root)\n",
"\tpwd            -- print the path to the current subterm\n",
"\tset [setting_options] var value\n",
"\t               -- set a parameter value\n",
"\tset            -- show parameter values\n",
"\tmark [path]    -- mark the given subterm (default is current) and quit\n",
"\tquit           -- quit browser\n",
"\thelp           -- show this help message\n",
"SICStus Prolog style commands are:\n",
"\tp              -- print\n",
"\t< n            -- set depth\n",
"\t^ [path]       -- cd to the specified subterm (default is root)\n",
"\t?              -- help\n",
"\th              -- help\n",
"\n",
"-- Parameter variables with integer values:\n",
"--  size <n>; depth <n>; path <n>; width <n>; lines <n>; num_io_actions <n>;\n",
"-- Parameter variables with non-integer values:\n",
"--  format <flat,raw_pretty,verbose,pretty>;\n",
"-- Paths can be Unix-style or SICStus-style: /2/3/1 or ^2^3^1\n",
"\n"],
		HelpMessage) },
	write_string_debugger(Debugger, HelpMessage).

%---------------------------------------------------------------------------%
%
% Various pretty-print routines
%

:- pred portray_maybe_path(debugger::in, browse_caller_type::in,
	maybe(portray_format)::in, browser_info::in,
	maybe(path)::in, io::di, io::uo) is cc_multi.

portray_maybe_path(Debugger, Caller, MaybeFormat, Info, MaybePath, !IO) :-
	(
		MaybePath = no,
		portray(Debugger, Caller, MaybeFormat, Info, !IO)
	;
		MaybePath = yes(Path),
		portray_path(Debugger, Caller, MaybeFormat, Info, Path, !IO)
	).

:- pred portray(debugger::in, browse_caller_type::in,
	maybe(portray_format)::in, browser_info::in,
	io::di, io::uo) is cc_multi.

portray(Debugger, Caller, MaybeFormat, Info, !IO) :-
	browser_info__get_format(Info, Caller, MaybeFormat, Format),
	browser_info__get_format_params(Info, Caller, Format, Params),
	deref_subterm(Info ^ term, Info ^ dirs, [], SubResult),
	(
		SubResult = deref_result(SubUniv),
		(
			Format = flat,
			portray_flat(Debugger, SubUniv, Params, !IO)
		;
			Format = raw_pretty,
			portray_raw_pretty(Debugger, SubUniv, Params, !IO)
		;
			Format = verbose,
			portray_verbose(Debugger, SubUniv, Params, !IO)
		;
			Format = pretty,
			portray_pretty(Debugger, SubUniv, Params, !IO)
		)
	;
		SubResult = deref_error(OKPath, ErrorDir),
		report_deref_error(Debugger, OKPath, ErrorDir, !IO)
		% write_string_debugger(Debugger, "error: no such subterm")
	),
	nl_debugger(Debugger, !IO).

:- pred portray_path(debugger::in, browse_caller_type::in,
	maybe(portray_format)::in, browser_info::in, path::in,
	io::di, io::uo) is cc_multi.

portray_path(Debugger, Caller, MaybeFormat, Info0, Path, !IO) :-
	set_path(Path, Info0, Info),
	portray(Debugger, Caller, MaybeFormat, Info, !IO).

:- pred portray_flat(debugger::in, browser_term::in, format_params::in,
	io::di, io::uo) is cc_multi.

portray_flat(Debugger, BrowserTerm, Params, !IO) :-
	%
	% io__write handles the special cases such as lists,
	% operators, etc. better, so we prefer to use it if we
	% can.  However, io__write doesn't have a depth or size limit,
	% so we need to check the size first; if the term is small
	% enough, we use io__write (actually io__write_univ), otherwise
	% we use term_to_string/4.
	%
	% XXX this ignores the maximum number of lines
	%
	browser_term_size_left_from_max(BrowserTerm, max_print_size,
		RemainingSize),
	( RemainingSize >= 0 ->
		portray_flat_write_browser_term(BrowserTerm, !IO)
	;
		io__get_stream_db(StreamDb, !IO),
		BrowserDb = browser_db(StreamDb),
		browser_term_to_string(BrowserDb, BrowserTerm, Params ^ size,
			Params ^ depth, Str),
		write_string_debugger(Debugger, Str, !IO)
	).

:- pred portray_flat_write_browser_term(browser_term::in,
	io::di, io::uo) is cc_multi.

portray_flat_write_browser_term(plain_term(Univ), !IO) :-
	io__output_stream(Stream, !IO),
	io__write_univ(Stream, include_details_cc, Univ, !IO).
portray_flat_write_browser_term(synthetic_term(Functor, Args, MaybeReturn),
		!IO) :-
	io__write_string(Functor, !IO),
	io__output_stream(Stream, !IO),
	( Args = [] ->
		true
	;
		io__write_string("(", !IO),
		io__write_list(Args, ", ", write_univ_or_unbound(Stream), !IO),
		io__write_string(")", !IO)
	),
	(
		MaybeReturn = yes(Return),
		io__write_string(" = ", !IO),
		io__write_univ(Stream, include_details_cc, Return, !IO)
	;
		MaybeReturn = no
	).

:- pred portray_verbose(debugger::in, browser_term::in, format_params::in,
	io::di, io::uo) is cc_multi.

portray_verbose(Debugger, BrowserTerm, Params, !IO) :-
	io__get_stream_db(StreamDb, !IO),
	BrowserDb = browser_db(StreamDb),
	browser_term_to_string_verbose(BrowserDb, BrowserTerm, Params ^ size,
		Params ^ depth, Params ^ width, Params ^ lines, Str),
	write_string_debugger(Debugger, Str, !IO).

:- pred portray_raw_pretty(debugger::in, browser_term::in, format_params::in,
	io::di, io::uo) is det.

portray_raw_pretty(Debugger, BrowserTerm, Params, !IO) :-
	browser_term_to_string_raw_pretty(BrowserTerm, Params ^ width,
		Params ^ depth, Str),
	write_string_debugger(Debugger, Str, !IO).

:- pred portray_pretty(debugger::in, browser_term::in, format_params::in,
	io::di, io::uo) is cc_multi.

portray_pretty(Debugger, BrowserTerm, Params, !IO) :-
	io__get_stream_db(StreamDb, !IO),
	BrowserDb = browser_db(StreamDb),
	sized_pretty__browser_term_to_string_line(BrowserDb, BrowserTerm,
		Params ^ width, Params ^ lines, Str),
	write_string_debugger(Debugger, Str, !IO).

	% The maximum estimated size for which we use `io__write'.
:- func max_print_size = int.

max_print_size = 60.

term_size_left_from_max(Univ, MaxSize, RemainingSize) :-
	( MaxSize < 0 ->
		RemainingSize = MaxSize
	;
		deconstruct__limited_deconstruct_cc(univ_value(Univ), MaxSize,
			MaybeFunctorArityArgs),
		(
			MaybeFunctorArityArgs = yes({Functor, Arity, Args}),
			string__length(Functor, FunctorSize),
			% "()", plus Arity-1 times ", "
			PrincipalSize = FunctorSize + Arity * 2,
			MaxArgsSize = MaxSize - PrincipalSize,
			list__foldl(term_size_left_from_max,
				Args, MaxArgsSize, RemainingSize)
		;
			MaybeFunctorArityArgs = no,
			RemainingSize = -1
		)
	;
		RemainingSize = -1
	).

browser_term_size_left_from_max(BrowserTerm, MaxSize, RemainingSize) :-
	(
		BrowserTerm = plain_term(Univ),
		term_size_left_from_max(Univ, MaxSize, RemainingSize)
	;
		BrowserTerm = synthetic_term(Functor, Args, MaybeReturn),
		string__length(Functor, FunctorSize),
		list__length(Args, Arity),
		(
			MaybeReturn = yes(_),
			% "()", " = ", plus Arity-1 times ", "
			PrincipalSize = FunctorSize + Arity * 2 + 3
		;
			MaybeReturn = no,
			% "()", plus Arity-1 times ", "
			PrincipalSize = FunctorSize + Arity * 2
		),
		MaxArgsSize = MaxSize - PrincipalSize,
		list__foldl(term_size_left_from_max,
			Args, MaxArgsSize, RemainingSize)
	).

:- pred write_univ_or_unbound(io__output_stream::in, univ::in, io::di, io::uo)
	is cc_multi.

write_univ_or_unbound(Stream, Univ, !IO) :-
	( univ_to_type(Univ, _ `with_type` unbound) ->
		io__write_char(Stream, '_', !IO)
	;
		io__write_univ(Stream, include_details_cc, Univ, !IO)
	).

:- pred report_deref_error(debugger::in, list(dir)::in, dir::in,
	io::di, io::uo) is det.

report_deref_error(Debugger, OKPath, ErrorDir, !IO) :-
	write_string_debugger(Debugger, "error: ", !IO),
	(
		OKPath = [_ | _],
		Context = "in subdir " ++ dirs_to_string(OKPath) ++ ": ",
		write_string_debugger(Debugger, Context, !IO)
	;
		OKPath = []
	),
	Msg = "there is no subterm " ++ dir_to_string(ErrorDir) ++ "\n",
	write_string_debugger(Debugger, Msg, !IO).

%---------------------------------------------------------------------------%
%
% Single-line representation of a term.
%

:- pred browser_term_to_string(browser_db::in, browser_term::in,
	int::in, int::in, string::out) is cc_multi.

browser_term_to_string(BrowserDb, BrowserTerm, MaxSize, MaxDepth, Str) :-
	CurSize = 0,
	CurDepth = 0,
	browser_term_to_string_2(BrowserDb, BrowserTerm,
		MaxSize, CurSize, _NewSize, MaxDepth, CurDepth, Str).

	% Note: When the size limit is reached, we simply display
	% further subterms compressed.  This is consistent with the
	% User's Guide, which describes the size limit as a "suggested
	% maximum".
:- pred browser_term_to_string_2(browser_db::in, browser_term::in,
	int::in, int::in, int::out, int::in, int::in, string::out) is cc_multi.

browser_term_to_string_2(BrowserDb, BrowserTerm, MaxSize, CurSize, NewSize,
		MaxDepth, CurDepth, Str) :-
	limited_deconstruct_browser_term_cc(BrowserDb, BrowserTerm, MaxSize,
		MaybeFunctorArityArgs, MaybeReturn),
	(
		CurSize < MaxSize,
		CurDepth < MaxDepth,
		MaybeFunctorArityArgs = yes({Functor, _Arity, Args})
	->
		browser_term_to_string_3(BrowserDb, Functor, Args, MaybeReturn,
			MaxSize, CurSize, NewSize, MaxDepth, CurDepth, Str)
	;
		browser_term_compress(BrowserDb, BrowserTerm, Str),
		NewSize = CurSize
	).

:- pred browser_term_to_string_3(browser_db::in, string::in,
	list(univ)::in, maybe(univ)::in, int::in, int::in, int::out,
	int::in, int::in, string::out) is cc_multi.

browser_term_to_string_3(BrowserDb, Functor, Args, MaybeReturn,
		MaxSize, Size0, Size, MaxDepth, Depth0, Str) :-
	(
		Functor = "[|]",
		Args = [ListHead, ListTail],
		MaybeReturn = no
	->
		% For the purposes of size and depth, we treat lists as if
		% they consist of one functor plus an argument for each
		% element of the list.
		Size1 = Size0 + 1,
		Depth1 = Depth0 + 1,
		browser_term_to_string_2(BrowserDb, plain_term(ListHead),
			MaxSize, Size1, Size2, MaxDepth, Depth1, HeadStr),
		list_tail_to_string_list(BrowserDb, ListTail,
			MaxSize, Size2, Size, MaxDepth, Depth1, TailStrs),
		list__append(TailStrs, ["]"], Strs),
		string__append_list(["[", HeadStr | Strs], Str)
	;
		Functor = "[]",
		Args = [],
		MaybeReturn = no
	->
		Size = Size0 + 1,
		Str = "[]"
	;
		Size1 = Size0 + 1,
		Depth1 = Depth0 + 1,
		args_to_string_list(BrowserDb, Args, MaxSize, Size1, Size2,
			MaxDepth, Depth1, ArgStrs),
		BracketedArgsStr = bracket_string_list(ArgStrs),
		(
			MaybeReturn = yes(Return),
			browser_term_to_string_2(BrowserDb, plain_term(Return),
				MaxSize, Size2, Size, MaxDepth, Depth1,
				ReturnStr),
			string__append_list([Functor, BracketedArgsStr,
				" = ", ReturnStr], Str)
		;
			MaybeReturn = no,
			Size = Size2,
			string__append_list([Functor, BracketedArgsStr], Str)
		)
	).

:- pred list_tail_to_string_list(browser_db::in, univ::in,
	int::in, int::in, int::out, int::in, int::in, list(string)::out)
	is cc_multi.

list_tail_to_string_list(BrowserDb, TailUniv, MaxSize, Size0, Size,
		MaxDepth, Depth0, TailStrs) :-

	% We want the limit to be at least two to ensure that the limited
	% deconstruct won't fail for any list term.
	Limit = max(MaxSize, 2),
	limited_deconstruct_browser_term_cc(BrowserDb, plain_term(TailUniv),
		Limit, MaybeFunctorArityArgs, MaybeReturn),
	(
		MaybeFunctorArityArgs = yes({Functor, _Arity, Args}),
		(
			Functor = "[]",
			Args = [],
			MaybeReturn = no
		->
			Size = Size0,
			TailStrs = []
		;
			Functor = "[|]",
			Args = [ListHead, ListTail],
			MaybeReturn = no
		->
			(
				Size0 < MaxSize,
				Depth0 < MaxDepth
			->
				browser_term_to_string_2(BrowserDb,
					plain_term(ListHead),
					MaxSize, Size0, Size1,
					MaxDepth, Depth0, HeadStr),
				list_tail_to_string_list(BrowserDb, ListTail,
					MaxSize, Size1, Size, MaxDepth, Depth0,
					TailStrs0),
				TailStrs = [", ", HeadStr | TailStrs0]
			;
				Size = Size0,
				TailStrs = [", ..."]
			)
		;
			(
				Size0 < MaxSize,
				Depth0 < MaxDepth
			->
				browser_term_to_string_3(BrowserDb,
					Functor, Args, MaybeReturn,
					MaxSize, Size0, Size,
					MaxDepth, Depth0, TailStr),
				TailStrs = [" | ", TailStr]
			;
				Size = Size0,
				browser_term_compress(BrowserDb,
					plain_term(TailUniv),
					TailCompressedStr),
				TailStrs = [" | ", TailCompressedStr]
			)
		)
	;
		MaybeFunctorArityArgs = no,
		Size = Size0,
		browser_term_compress(BrowserDb, plain_term(TailUniv),
			TailCompressedStr),
		TailStrs = [" | ", TailCompressedStr]
	).

:- pred args_to_string_list(browser_db::in, list(univ)::in,
	int::in, int::in, int::out, int::in, int::in, list(string)::out)
	is cc_multi.

args_to_string_list(_BrowserDb, [], _MaxSize, CurSize, NewSize,
		_MaxDepth, _CurDepth, Strs) :-
	Strs = [],
	NewSize = CurSize.
args_to_string_list(BrowserDb, [Univ | Univs], MaxSize, CurSize, NewSize,
		MaxDepth, CurDepth, Strs) :-
	browser_term_to_string_2(BrowserDb, plain_term(Univ),
		MaxSize, CurSize, NewSize1, MaxDepth, CurDepth, Str),
	args_to_string_list(BrowserDb, Univs, MaxSize, NewSize1, NewSize,
		MaxDepth, CurDepth, RestStrs),
	Strs = [Str | RestStrs].

:- func bracket_string_list(list(string)) = string.

bracket_string_list(Args) = Str :-
	( Args = [] ->
		Str = ""
	;
		string__append_list(["(", comma_string_list(Args), ")"], Str)
	).

:- func comma_string_list(list(string)) = string.

comma_string_list(Args) = Str :-
	(
		Args = [],
		Str = ""
	;
		Args = [S],
		Str = S
	;
		Args = [S1, S2 | Ss],
		Rest = comma_string_list([S2 | Ss]),
		string__append_list([S1, ", ", Rest], Str)
	).

:- pred browser_term_compress(browser_db::in, browser_term::in, string::out)
	is cc_multi.

browser_term_compress(BrowserDb, BrowserTerm, Str) :-
	functor_browser_term_cc(BrowserDb, BrowserTerm, Functor, Arity, IsFunc),
	( Arity = 0 ->
		Str = Functor
	;
		int_to_string(Arity, ArityStr),
		(
			IsFunc = yes,
			append_list([Functor, "/", ArityStr, "+1"], Str)
		;
			IsFunc = no,
			append_list([Functor, "/", ArityStr], Str)
		)
	).

%---------------------------------------------------------------------------%
%
% Print using the pretty printer from the standard library.
% XXX the size of the term is not limited---the pretty printer
% provides no way of doing this.
%

:- pred browser_term_to_string_raw_pretty(browser_term::in, int::in, int::in,
	string::out) is det.

browser_term_to_string_raw_pretty(plain_term(Univ), Width, MaxDepth, Str) :-
	Value = univ_value(Univ),
	Doc = to_doc(MaxDepth, Value),
	Str = to_string(Width, Doc).
browser_term_to_string_raw_pretty(synthetic_term(Functor, Args, MaybeReturn),
		Width, MaxDepth, Str) :-
	Doc = synthetic_term_to_doc(MaxDepth, Functor, Args, MaybeReturn),
	Str = to_string(Width, Doc).

%---------------------------------------------------------------------------%
%
% Verbose printing. Tree layout with numbered branches.
% Numbering makes it easier to change to subterms.
%

:- pred browser_term_to_string_verbose(browser_db::in, browser_term::in,
	int::in, int::in, int::in, int::in, string::out) is cc_multi.

browser_term_to_string_verbose(BrowserDb, BrowserTerm, MaxSize, MaxDepth,
		X, Y, Str) :-
	CurSize = 0,
	CurDepth = 0,
	browser_term_to_string_verbose_2(BrowserDb, BrowserTerm,
		MaxSize, CurSize, _NewSize, MaxDepth, CurDepth, Frame),
	frame__clip(X-Y, Frame, ClippedFrame),
	unlines(ClippedFrame, Str).

:- pred browser_term_to_string_verbose_2(browser_db::in, browser_term::in,
	int::in, int::in, int::out, int::in, int::in, frame::out) is cc_multi.

browser_term_to_string_verbose_2(BrowserDb, BrowserTerm,
		MaxSize, CurSize, NewSize, MaxDepth, CurDepth, Frame) :-
	limited_deconstruct_browser_term_cc(BrowserDb, BrowserTerm, MaxSize,
		MaybeFunctorArityArgs, MaybeReturn),
	(
		CurSize < MaxSize,
		CurDepth < MaxDepth,
		MaybeFunctorArityArgs = yes({Functor, _Arity, Args0})
	->
		% XXX we should consider formatting function terms differently.
		(
			MaybeReturn = yes(Return),
			list__append(Args0, [Return], Args)
		;
			MaybeReturn = no,
			Args = Args0
		),
		CurSize1 = CurSize + 1,
		CurDepth1 = CurDepth + 1,
		ArgNum = 1,
		args_to_string_verbose_list(BrowserDb, Args, ArgNum,
			MaxSize, CurSize1, NewSize, MaxDepth, CurDepth1,
			ArgsFrame),
		frame__vglue([Functor], ArgsFrame, Frame)
	;
		browser_term_compress(BrowserDb, BrowserTerm, Line),
		Frame = [Line],
		NewSize = CurSize
	).

:- pred args_to_string_verbose_list(browser_db::in, list(univ)::in,
	int::in, int::in, int::in, int::out, int::in, int::in, frame::out)
	is cc_multi.

args_to_string_verbose_list(_BrowserDb, [], _ArgNum,
		_MaxSize, CurSize, NewSize, _MaxDepth, _CurDepth, []) :-
	NewSize = CurSize.
args_to_string_verbose_list(BrowserDb, [Univ], ArgNum,
		MaxSize, CurSize, NewSize, MaxDepth, CurDepth, Frame) :-
	browser_term_to_string_verbose_2(BrowserDb, plain_term(Univ), MaxSize,
		CurSize, NewSize, MaxDepth, CurDepth, TreeFrame),
	% XXX: ArgNumS must have fixed length 2.
	string__int_to_string(ArgNum, ArgNumS),
	string__append_list([ArgNumS, "-"], LastBranchS),
	frame__hglue([LastBranchS], TreeFrame, Frame).
args_to_string_verbose_list(BrowserDb, [Univ1, Univ2 | Univs], ArgNum, MaxSize,
		CurSize, NewSize, MaxDepth, CurDepth, Frame) :-
	browser_term_to_string_verbose_2(BrowserDb, plain_term(Univ1),
		MaxSize, CurSize, NewSize1, MaxDepth, CurDepth, TreeFrame),
	ArgNum1 = ArgNum + 1,
	args_to_string_verbose_list(BrowserDb, [Univ2 | Univs], ArgNum1,
		MaxSize, NewSize1, NewSize2, MaxDepth, CurDepth,
		RestTreesFrame),
	NewSize = NewSize2,
	% XXX: ArgNumS must have fixed length 2.
	string__int_to_string(ArgNum, ArgNumS),
	string__append_list([ArgNumS, "-"], BranchFrameS),
	frame__vsize(TreeFrame, Height),
	Height1 = Height - 1,
	list__duplicate(Height1, "|", VBranchFrame),
	frame__vglue([BranchFrameS], VBranchFrame, LeftFrame),
	frame__hglue(LeftFrame, TreeFrame, TopFrame),
	frame__vglue(TopFrame, RestTreesFrame, Frame).

:- pred unlines(list(string)::in, string::out) is det.

unlines([], "").
unlines([Line | Lines], Str) :-
	string__append(Line, "\n", NLine),
	unlines(Lines, Strs),
	string__append(NLine, Strs, Str).

%---------------------------------------------------------------------------%
%
% Miscellaneous path handling
%

:- pred write_path(debugger::in, list(dir)::in, io::di, io::uo) is det.

write_path(Debugger, [], !IO) :-
	write_string_debugger(Debugger, "/", !IO).
write_path(Debugger, [Dir], !IO) :-
	(
		Dir = parent,
		write_string_debugger(Debugger, "/", !IO)
	;
		Dir = child_num(N),
		write_string_debugger(Debugger, "/", !IO),
		write_int_debugger(Debugger, N, !IO)
	;
		Dir = child_name(Name),
		write_string_debugger(Debugger, "/", !IO),
		write_string_debugger(Debugger, Name, !IO)
	).
write_path(Debugger, [Dir, Dir2 | Dirs], !IO) :-
	write_path_2(Debugger, [Dir, Dir2 | Dirs], !IO).

:- pred write_path_2(debugger::in, list(dir)::in, io::di, io::uo) is det.

write_path_2(Debugger, [], !IO) :-
	write_string_debugger(Debugger, "/", !IO).
write_path_2(Debugger, [Dir], !IO) :-
	(
		Dir = parent,
		write_string_debugger(Debugger, "/..", !IO)
	;
		Dir = child_num(N),
		write_string_debugger(Debugger, "/", !IO),
		write_int_debugger(Debugger, N, !IO)
	;
		Dir = child_name(Name),
		write_string_debugger(Debugger, "/", !IO),
		write_string_debugger(Debugger, Name, !IO)
	).
write_path_2(Debugger, [Dir, Dir2 | Dirs], !IO) :-
	(
		Dir = parent,
		write_string_debugger(Debugger, "/..", !IO),
		write_path_2(Debugger, [Dir2 | Dirs], !IO)
	;
		Dir = child_num(N),
		write_string_debugger(Debugger, "/", !IO),
		write_int_debugger(Debugger, N, !IO),
		write_path_2(Debugger, [Dir2 | Dirs], !IO)
	;
		Dir = child_name(Name),
		write_string_debugger(Debugger, "/", !IO),
		write_string_debugger(Debugger, Name, !IO),
		write_path_2(Debugger, [Dir2 | Dirs], !IO)
	).

:- type deref_result(T)
	--->	deref_result(T)
	;	deref_error(list(dir), dir).

	% We assume a root-relative path. We assume Term is the entire term
	% passed into browse/3, not a subterm.
:- pred deref_subterm(browser_term::in, list(dir)::in, list(dir)::in,
	deref_result(browser_term)::out) is det.

deref_subterm(BrowserTerm, Path, RevPath0, Result) :-
	simplify_dirs(Path, SimplifiedPath),
	(
		BrowserTerm = plain_term(Univ),
		deref_subterm_2(Univ, SimplifiedPath, RevPath0, SubResult),
		deref_result_univ_to_browser_term(SubResult, Result)
	;
		BrowserTerm = synthetic_term(_Functor, Args, MaybeReturn),
		(
			SimplifiedPath = [],
			SubBrowserTerm = BrowserTerm,
			Result = deref_result(SubBrowserTerm)
		;
			SimplifiedPath = [Step | SimplifiedPathTail],
			(
				(
					Step = child_num(N),
					% The first argument of a non-array
					% is numbered argument 1.
					list__index1(Args, N, ArgUniv)
				;
					Step = child_name(Name),
					MaybeReturn = yes(ArgUniv),
					( Name = "r"
					; Name = "res"
					; Name = "result"
					)
				;
					Step = parent,
					error("deref_subterm: found parent")
				)
			->
				deref_subterm_2(ArgUniv, SimplifiedPathTail,
					[Step | RevPath0], SubResult),
				deref_result_univ_to_browser_term(SubResult,
					Result)
			;
				Result = deref_error(list__reverse(RevPath0),
					Step)
			)
		)
	).

:- pred deref_result_univ_to_browser_term(deref_result(univ)::in,
	deref_result(browser_term)::out) is det.

deref_result_univ_to_browser_term(SubResult, Result) :-
	(
		SubResult = deref_result(SubUniv),
		SubBrowserTerm = plain_term(SubUniv),
		Result = deref_result(SubBrowserTerm)
	;
		SubResult = deref_error(OKPath, ErrorDir),
		Result = deref_error(OKPath, ErrorDir)
	).

:- pred deref_subterm_2(univ::in, list(dir)::in, list(dir)::in,
	deref_result(univ)::out) is det.

deref_subterm_2(Univ, Path, RevPath0, Result) :-
	(
		Path = [],
		Result = deref_result(Univ)
	;
		Path = [Dir | Dirs],
		(
			(
				Dir = child_num(N),
				(
					TypeCtor = type_ctor(univ_type(Univ)),
					type_ctor_name(TypeCtor) = "array",
					type_ctor_module_name(TypeCtor) =
						"array"
				->
						% The first element of an array
						% is at index zero.
					ArgN = argument(univ_value(Univ), N)
				;
					% The first argument of a non-array is
					% numbered argument 1 by the user
					% but argument 0 by std_util:argument.
					ArgN = argument(univ_value(Univ),
						N - 1)
				)
			;
				Dir = child_name(Name),
				ArgN = named_argument(univ_value(Univ), Name)
			;
				Dir = parent,
				error("deref_subterm_2: found parent")
			)
		->
			deref_subterm_2(ArgN, Dirs, [Dir | RevPath0], Result)
		;
			Result = deref_error(list__reverse(RevPath0), Dir)
		)
	).

%---------------------------------------------------------------------------%

:- pred get_path(browser_info::in, path::out) is det.

get_path(Info, root_rel(Info ^ dirs)).

:- pred set_path(path::in, browser_info::in, browser_info::out) is det.

set_path(NewPath, Info0, Info) :-
	change_dir(Info0 ^ dirs, NewPath, NewDirs),
	Info = Info0 ^ dirs := NewDirs.

:- pred change_dir(list(dir)::in, path::in, list(dir)::out) is det.

change_dir(PwdDirs, Path, RootRelDirs) :-
	(
		Path = root_rel(Dirs),
		NewDirs = Dirs
	;
		Path = dot_rel(Dirs),
		list__append(PwdDirs, Dirs, NewDirs)
	),
	simplify_dirs(NewDirs, RootRelDirs).

:- pred set_term(univ::in, browser_info::in, browser_info::out) is det.

set_term(Term, Info0, Info) :-
	set_browser_term(plain_term(Term), Info0, Info1),
	% Display from the root term.
	% This avoid errors due to dereferencing non-existent subterms.
	set_path(root_rel([]), Info1, Info).

:- pred set_browser_term(browser_term::in, browser_info::in, browser_info::out)
	is det.

set_browser_term(BrowserTerm, Info, Info ^ term := BrowserTerm).

%---------------------------------------------------------------------------%
%
% Display predicates.
%

:- pred show_settings(debugger::in, browser_info::in,
	io::di, io::uo) is det.

show_settings(Debugger, Info, !IO) :-
	show_settings_caller(Debugger, Info, browse, "Browser", !IO),
	show_settings_caller(Debugger, Info, print, "Print", !IO),
	show_settings_caller(Debugger, Info, print_all, "Printall", !IO),

	write_string_debugger(Debugger, "Current path is: ", !IO),
	write_path(Debugger, Info ^ dirs, !IO),
	nl_debugger(Debugger, !IO),

	write_string_debugger(Debugger,
		"Number of I/O actions printed is: ", !IO),
	write_int_debugger(Debugger,
		get_num_printed_io_actions(Info ^ state), !IO),
	nl_debugger(Debugger, !IO).

:- pred show_settings_caller(debugger::in, browser_info::in,
	browse_caller_type::in, string::in,
	io::di, io::uo) is det.

show_settings_caller(Debugger, Info, Caller, CallerName, !IO) :-
	browser_info__get_format(Info, Caller, no, Format),
	write_string_debugger(Debugger,
		CallerName ++ " default format: ", !IO),
	print_format_debugger(Debugger, Format, !IO),
	nl_debugger(Debugger, !IO),

	write_string_debugger(Debugger,
		pad_right("", ' ', row_name_len), !IO),
	write_string_debugger(Debugger,
		pad_right("depth", ' ', depth_len), !IO),
	write_string_debugger(Debugger,
		pad_right("size", ' ', size_len), !IO),
	write_string_debugger(Debugger,
		pad_right("x clip", ' ', x_len), !IO),
	write_string_debugger(Debugger,
		pad_right("y clip", ' ', y_len), !IO),
	nl_debugger(Debugger, !IO),

	show_settings_caller_format(Debugger, Info, Caller, CallerName,
		flat, "flat", !IO),
	show_settings_caller_format(Debugger, Info, Caller, CallerName,
		verbose, "verbose", !IO),
	show_settings_caller_format(Debugger, Info, Caller, CallerName,
		pretty, "pretty", !IO),
	show_settings_caller_format(Debugger, Info, Caller, CallerName,
		raw_pretty, "raw_pretty", !IO),
	nl_debugger(Debugger, !IO).

:- pred show_settings_caller_format(debugger::in, browser_info::in,
	browse_caller_type::in, string::in, portray_format::in, string::in,
	io::di, io::uo) is det.

show_settings_caller_format(Debugger, Info, Caller, CallerName,
		Format, FormatName, !IO) :-
	browser_info__get_format_params(Info, Caller, Format, Params),
	write_string_debugger(Debugger,
		pad_right(CallerName ++ " " ++ FormatName ++ ":",
			' ', row_name_len),
		!IO),
	write_string_debugger(Debugger,
		pad_right(" ", ' ', centering_len), !IO),
	write_string_debugger(Debugger,
		pad_right(int_to_string(Params ^ depth), ' ', depth_len), !IO),
	write_string_debugger(Debugger,
		pad_right(int_to_string(Params ^ size), ' ', size_len), !IO),
	write_string_debugger(Debugger,
		pad_right(int_to_string(Params ^ width), ' ', x_len), !IO),
	write_string_debugger(Debugger,
		pad_right(int_to_string(Params ^ lines), ' ', y_len), !IO),
	nl_debugger(Debugger, !IO).

:- func row_name_len = int.
:- func centering_len = int.
:- func depth_len = int.
:- func size_len = int.
:- func x_len = int.
:- func y_len = int.

row_name_len  = 30.
centering_len =  3.
depth_len     = 10.
size_len      = 10.
x_len         = 10.
y_len         = 10.

:- pred string_to_path(string::in, path::out) is semidet.

string_to_path(Str, Path) :-
	string__to_char_list(Str, Cs),
	chars_to_path(Cs, Path).

:- pred chars_to_path(list(char)::in, path::out) is semidet.

chars_to_path([C | Cs], Path) :-
	( C = ('/') ->
		Path = root_rel(Dirs),
		chars_to_dirs(Cs, Dirs)
	;
		Path = dot_rel(Dirs),
		chars_to_dirs([C | Cs], Dirs)
	).

:- pred chars_to_dirs(list(char)::in, list(dir)::out) is semidet.

chars_to_dirs(Cs, Dirs) :-
	split_dirs(Cs, Names),
	names_to_dirs(Names, Dirs).

:- pred names_to_dirs(list(string)::in, list(dir)::out) is semidet.

names_to_dirs([], []).
names_to_dirs([Name | Names], Dirs) :-
	( Name = ".." ->
		Dirs = [parent | RestDirs],
		names_to_dirs(Names, RestDirs)
	; Name = "." ->
		names_to_dirs(Names, Dirs)
	; string__to_int(Name, Num) ->
		Dirs = [child_num(Num) | RestDirs],
		names_to_dirs(Names, RestDirs)
	;
		Dirs = [child_name(Name) | RestDirs],
		names_to_dirs(Names, RestDirs)
	).

:- pred split_dirs(list(char)::in, list(string)::out) is det.

split_dirs(Cs, Names) :-
	takewhile(not_slash, Cs, NameCs, Rest),
	string__from_char_list(NameCs, Name),
	( NameCs = [] ->
		Names = []
	; Rest = [] ->
		Names = [Name]
	; Rest = [_Slash | RestCs] ->
		split_dirs(RestCs, RestNames),
		Names = [Name | RestNames]
	;
		error("split_dirs: software error")
	).

:- pred not_slash(char::in) is semidet.

not_slash(C) :-
	C \= ('/').

	% Remove "/dir/../" sequences from a list of directories to yield
	% a form that lacks ".." entries.
	% NB: This can be done more efficiently than simple iteration
	% to a limit.
:- pred simplify_dirs(list(dir)::in, list(dir)::out) is det.

simplify_dirs(Dirs, SimpleDirs) :-
	util__limit(simplify, Dirs, SimpleDirs).

	% If possible, remove a single occurence of
	% either:
	%	- "dir/../"
	% or:
	%	- "/.." (parent of root is root)
	%
:- pred simplify(list(dir)::in, list(dir)::out) is det.

simplify([], []).
simplify([First | Rest], Simplified) :-
	( First = parent ->
		Simplified = Rest
	; Rest = [] ->
		Simplified = [First]
	; Rest = [parent | Tail] ->
		Simplified = Tail
	;
		simplify(Rest, SimplifiedRest),
		Simplified = [First | SimplifiedRest]
	).

:- func dir_to_string(dir) = string.

dir_to_string(parent) = "..".
dir_to_string(child_num(Num)) = int_to_string(Num).
dir_to_string(child_name(Name)) = Name.

:- func dirs_to_string(list(dir)) = string.

dirs_to_string([]) = "".
dirs_to_string([Dir | Dirs]) =
	( Dirs = [] ->
		dir_to_string(Dir)
	;
		dir_to_string(Dir) ++ "/" ++ dirs_to_string(Dirs)
	).

%---------------------------------------------------------------------------%

:- pred write_string_debugger(debugger::in, string::in, io::di, io::uo) is det.

write_string_debugger(internal, String, !IO) :-
	io__write_string(String, !IO).
write_string_debugger(external, String, !IO) :-
	send_term_to_socket(browser_str(String), !IO).

:- pred nl_debugger(debugger::in, io::di, io::uo) is det.

nl_debugger(internal, !IO) :-
	io__nl(!IO).
nl_debugger(external, !IO) :-
	send_term_to_socket(browser_nl, !IO).

:- pred write_int_debugger(debugger::in, int::in, io::di, io::uo) is det.

write_int_debugger(internal, Int, !IO) :-
	io__write_int(Int, !IO).
write_int_debugger(external, Int, !IO) :-
	send_term_to_socket(browser_int(Int), !IO).

:- pred print_format_debugger(debugger::in, portray_format::in,
	io::di, io::uo) is det.

print_format_debugger(internal, X, !IO) :-
	io__print(X, !IO).
print_format_debugger(external, X, !IO) :-
	(
		X = flat,
		send_term_to_socket(browser_str("flat"), !IO)
	;
		X = raw_pretty,
		send_term_to_socket(browser_str("raw_pretty"), !IO)
	;
		X = verbose,
		send_term_to_socket(browser_str("verbose"), !IO)
	;
		X = pretty,
		send_term_to_socket(browser_str("pretty"), !IO)
	).

:- pred send_term_to_socket(term_browser_response::in, io::di, io::uo) is det.

send_term_to_socket(Term, !IO) :-
	write(Term, !IO),
	print(".\n", !IO),
	flush_output(!IO).

%---------------------------------------------------------------------------%

    % These two functions are just like like pprint:to_doc, except their input
    % is not a natural term, but a synthetic term defined by a functor, a list
    % of arguments, and if the synthetic term is a function application, then
    % the result of that function application.

:- func synthetic_term_to_doc(string, list(univ), maybe(univ))      = doc.
:- func synthetic_term_to_doc(int, string, list(univ), maybe(univ)) = doc.

synthetic_term_to_doc(Functor, Args, MaybeReturn) =
	synthetic_term_to_doc(int__max_int, Functor, Args, MaybeReturn).

synthetic_term_to_doc(Depth, Functor, Args, MaybeReturn) = Doc :-
	Arity = list__length(Args),
	( Depth =< 0 ->
		( Arity = 0 ->
			Doc = text(Functor)
		;
			(
				MaybeReturn = yes(_),
				Doc = text(Functor) `<>` text("/") `<>`
					poly(i(Arity)) `<>` text("+1")
			;
				MaybeReturn = no,
				Doc = text(Functor) `<>` text("/") `<>`
					poly(i(Arity))
			)
		)
	;
		( Arity = 0 ->
			Doc = text(Functor)
		;
			ArgDocs = packed_cs_univ_args(Depth - 1, Args),
			(
				MaybeReturn = yes(Return),
				Doc = group(
					text(Functor) `<>`
					parentheses(
						nest(2, ArgDocs)
					) `<>`
					nest(2, text(" = ") `<>`
						to_doc(Depth - 1, Return)
					)
				)
			;
				MaybeReturn = no,
				Doc = group(
					text(Functor) `<>` parentheses(
						nest(2, ArgDocs)
					)
				)
			)
		)
	).

%---------------------------------------------------------------------------%
