/*
INIT mercury_sys_init_wrapper
ENDINIT
*/
/*
** Copyright (C) 1994-1998 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** file: mercury_wrapper.c
** main authors: zs, fjh
**
**	This file contains the startup and termination entry points
**	for the Mercury runtime.
**
**	It defines mercury_runtime_init(), which is invoked from
**	mercury_init() in the C file generated by util/mkinit.c.
**	The code for mercury_runtime_init() initializes various things, and
**	processes options (which are specified via an environment variable).
**
**	It also defines mercury_runtime_main(), which invokes
**	call_engine(do_interpreter), which invokes main/2.
**
**	It also defines mercury_runtime_terminate(), which performs
**	various cleanups that are needed to terminate cleanly.
*/

#include	"mercury_imp.h"

#include	<stdio.h>
#include	<ctype.h>
#include	<string.h>

#include	"mercury_timing.h"
#include	"mercury_getopt.h"
#include	"mercury_init.h"
#include	"mercury_dummy.h"
#include	"mercury_trace.h"

/* global variables concerned with testing (i.e. not with the engine) */

/* command-line options */

/* size of data areas (including redzones), in kilobytes */
/* (but we later multiply by 1024 to convert to bytes) */
size_t		heap_size =      	4096;
size_t		detstack_size =  	2048;
size_t		nondstack_size =  	128;
size_t		solutions_heap_size =	1024;
size_t		global_heap_size =	1024;
size_t		trail_size =		128;

/* size of the redzones at the end of data areas, in kilobytes */
/* (but we later multiply by 1024 to convert to bytes) */
size_t		heap_zone_size =	16;
size_t		detstack_zone_size =	16;
size_t		nondstack_zone_size =	16;
size_t		solutions_heap_zone_size = 16;
size_t		global_heap_zone_size =	16;
size_t		trail_zone_size =	16;

/* primary cache size to optimize for, in kilobytes */
/* (but we later multiply by 1024 to convert to bytes) */
size_t		pcache_size =    8192;

/* other options */

bool		check_space = FALSE;

static	bool	benchmark_all_solns = FALSE;
static	bool	use_own_timer = FALSE;
static	int	repeats = 1;

unsigned	MR_num_threads = 1;

/* timing */
int		time_at_last_stat;
int		time_at_start;
static	int	time_at_finish;

/* time profiling */
enum MR_TimeProfileMethod
		MR_time_profile_method = MR_profile_user_plus_system_time;

const char *	progname;
int		mercury_argc;	/* not counting progname */
char **		mercury_argv;
int		mercury_exit_status = 0;

bool		MR_profiling = TRUE;

/*
** EXTERNAL DEPENDENCIES
**
** - The Mercury runtime initialization, namely mercury_runtime_init(),
**   calls the functions init_gc() and init_modules(), which are in
**   the automatically generated C init file; mercury_init_io(), which is
**   in the Mercury library; and it calls the predicate io__init_state/2
**   in the Mercury library.
** - The Mercury runtime main, namely mercury_runtime_main(),
**   calls main/2 in the user's program.
** - The Mercury runtime finalization, namely mercury_runtime_terminate(),
**   calls io__finalize_state/2 in the Mercury library.
**
** But, to enable Quickstart of shared libraries on Irix 5,
** and in general to avoid various other complications
** with shared libraries and/or Windows DLLs,
** we need to make sure that we don't have any undefined
** external references when building the shared libraries.
** Hence the statically linked init file saves the addresses of those
** procedures in the following global variables.
** This ensures that there are no cyclic dependencies;
** the order is user program -> library -> runtime -> gc,
** where `->' means "depends on", i.e. "references a symbol of".
*/

void	(*address_of_mercury_init_io)(void);
void	(*address_of_init_modules)(void);
#ifdef CONSERVATIVE_GC
void	(*address_of_init_gc)(void);
#endif

Code	*program_entry_point;
		/* normally mercury__main_2_0 (main/2) */
void	(*MR_library_initializer)(void);
		/* normally ML_io_init_state (io__init_state/2)*/
void	(*MR_library_finalizer)(void);
		/* normally ML_io_finalize_state (io__finalize_state/2) */
Code	*MR_library_trace_browser;
		/* normally mercury__io__print_3_0 (io__print/3) */
void	(*MR_DI_output_current_ptr)(Integer, Integer, Integer, Word, String,
		String, Integer, Integer, Integer, Word, String, Word, Word);
		/* normally ML_DI_output_current (output_current/13) */
bool	(*MR_DI_found_match)(Integer, Integer, Integer, Word, String, String,
		Integer, Integer, Integer, Word, String, Word);
		/* normally ML_DI_found_match (output_current/12) */
void	(*MR_DI_read_request_from_socket)(Word, Word *, Integer *);

#ifdef USE_GCC_NONLOCAL_GOTOS

#define	SAFETY_BUFFER_SIZE	1024	/* size of stack safety buffer */
#define	MAGIC_MARKER_2		142	/* a random character */

#endif

static	void	process_args(int argc, char **argv);
static	void	process_environment_options(void);
static	void	process_options(int argc, char **argv);
static	void	usage(void);
static	void	make_argv(const char *, char **, char ***, int *);

#ifdef MEASURE_REGISTER_USAGE
static	void	print_register_usage_counts(void);
#endif

Declare_entry(do_interpreter);

/*---------------------------------------------------------------------------*/

void
mercury_runtime_init(int argc, char **argv)
{
	bool	saved_trace_enabled;

#if NUM_REAL_REGS > 0
	Word c_regs[NUM_REAL_REGS];
#endif

	/*
	** Save the callee-save registers; we're going to start using them
	** as global registers variables now, which will clobber them,
	** and we need to preserve them, because they're callee-save,
	** and our caller may need them ;-)
	*/
	save_regs_to_mem(c_regs);

#ifdef	MR_LOWLEVEL_DEBUG
	/*
	** Ensure stdio & stderr are unbuffered even if redirected.
	** Using setvbuf() is more complicated than using setlinebuf(),
	** but also more portable.
	*/

	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
#endif

#ifdef CONSERVATIVE_GC
	GC_quiet = TRUE;

	/*
	** Call GC_INIT() to tell the garbage collector about this DLL.
	** (This is necessary to support Windows DLLs using gnu-win32.)
	*/
	GC_INIT();

	/*
	** call the init_gc() function defined in <foo>_init.c,
	** which calls GC_INIT() to tell the GC about the main program.
	** (This is to work around a Solaris 2.X (X <= 4) linker bug,
	** and also to support Windows DLLs using gnu-win32.)
	*/
	(*address_of_init_gc)();

	/*
	** Double-check that the garbage collector knows about
	** global variables in shared libraries.
	*/
	GC_is_visible(&MR_runqueue);

	/* The following code is necessary to tell the conservative */
	/* garbage collector that we are using tagged pointers */
	{
		int i;

		for (i = 1; i < (1 << TAGBITS); i++) {
			GC_register_displacement(i);
		}
	}
#endif

	/*
	** Process the command line and the options in the environment
	** variable MERCURY_OPTIONS, and save results in global variables.
	*/

	process_args(argc, argv);
	process_environment_options();

	/*
	** Some of the rest of this function may call Mercury code
	** that may have been compiled with tracing (e.g. the initialization
	** routines in the library called via MR_library_initializer).
	** Since this initialization code shouldn't be traced, we disable
	** tracing until the end of this function.
	*/

	saved_trace_enabled = MR_trace_enabled;
	MR_trace_enabled = FALSE;

#ifdef MR_NEED_INITIALIZATION_AT_START
	do_init_modules();
#endif

	(*address_of_mercury_init_io)();

	/* start up the Mercury engine */
#ifndef MR_THREAD_SAFE
	init_thread((void *) 1);
#else
	{
		int i;
		init_thread_stuff();
		init_thread((void *)1);
		MR_exit_now = FALSE;
		for (i = 1 ; i < MR_num_threads ; i++)
			create_thread(0);
	}
#endif

	/* initialize profiling */
	if (MR_profiling) MR_prof_init();

	/*
	** We need to call save_registers(), since we're about to
	** call a C->Mercury interface function, and the C->Mercury
	** interface convention expects them to be saved.  And before we
	** can do that, we need to call restore_transient_registers(),
	** since we've just returned from a C call.
	*/
	restore_transient_registers();
	save_registers();

	MR_trace_init();

	/* initialize the Mercury library */
	(*MR_library_initializer)();

	save_context(&(MR_ENGINE(context)));

	/*
	** Now the real tracing starts; undo any updates to the trace state
	** made by the trace code in the library initializer.
	*/
	MR_trace_start(saved_trace_enabled);

	/*
	** Restore the callee-save registers before returning,
	** since they may be used by the C code that called us.
	*/
	restore_regs_from_mem(c_regs);

} /* end runtime_mercury_main() */

void 
do_init_modules(void)
{
	static	bool	done = FALSE;

	if (! done) {
		(*address_of_init_modules)();
		done = TRUE;
	}
}

/*
** Given a string, parse it into arguments and create an argv vector for it.
** Returns args, argv, and argc.  It is the caller's responsibility to oldmem()
** args and argv when they are no longer needed.
*/

static void
make_argv(const char *string, char **args_ptr, char ***argv_ptr, int *argc_ptr)
{
	char *args;
	char **argv;
	const char *s = string;
	char *d;
	int args_len = 0;
	int argc = 0;
	int i;
	
	/*
	** First do a pass over the string to count how much space we need to
	** allocate
	*/

	for (;;) {
		/* skip leading whitespace */
		while(isspace((unsigned char)*s)) {
			s++;
		}

		/* are there any more args? */
		if(*s != '\0') {
			argc++;
		} else {
			break;
		}

		/* copy arg, translating backslash escapes */
		if (*s == '"') {
			s++;
			/* "double quoted" arg - scan until next double quote */
			while (*s != '"') {
				if (s == '\0') {
					fatal_error(
				"Mercury runtime: unterminated quoted string\n"
				"in MERCURY_OPTIONS environment variable\n"
					);
				}
				if (*s == '\\')
					s++;
				args_len++; s++;
			}
			s++;
		} else {
			/* ordinary white-space delimited arg */
			while(*s != '\0' && !isspace((unsigned char)*s)) {
				if (*s == '\\')
					s++;
				args_len++; s++;
			}
		}
		args_len++;
	} /* end for */

	/*
	** Allocate the space
	*/
	args = make_many(char, args_len);
	argv = make_many(char *, argc + 1);

	/*
	** Now do a pass over the string, copying the arguments into `args'
	** setting up the contents of `argv' to point to the arguments.
	*/
	s = string;
	d = args;
	for(i = 0; i < argc; i++) {
		/* skip leading whitespace */
		while(isspace((unsigned char)*s)) {
			s++;
		}

		/* are there any more args? */
		if(*s != '\0') {
			argv[i] = d;
		} else {
			argv[i] = NULL;
			break;
		}

		/* copy arg, translating backslash escapes */
		if (*s == '"') {
			s++;
			/* "double quoted" arg - scan until next double quote */
			while (*s != '"') {
				if (*s == '\\')
					s++;
				*d++ = *s++;
			}
			s++;
		} else {
			/* ordinary white-space delimited arg */
			while(*s != '\0' && !isspace((unsigned char)*s)) {
				if (*s == '\\')
					s++;
				*d++ = *s++;
			}
		}
		*d++ = '\0';
	} /* end for */

	*args_ptr = args;
	*argv_ptr = argv;
	*argc_ptr = argc;
} /* end make_argv() */


/**  
 **  process_args() is a function that sets some global variables from the
 **  command line.  `mercury_arg[cv]' are `arg[cv]' without the program name.
 **  `progname' is program name.
 **/

static void
process_args( int argc, char ** argv)
{
	progname = argv[0];
	mercury_argc = argc - 1;
	mercury_argv = argv + 1;
}


/**
 **  process_environment_options() is a function to parse the MERCURY_OPTIONS
 **  environment variable.  
 **/ 

static void
process_environment_options(void)
{
	char*	options;

	options = getenv("MERCURY_OPTIONS");
	if (options != NULL) {
		char	*arg_str, **argv;
		char	*dummy_command_line;
		int	argc;
		int	c;

		/*
		   getopt() expects the options to start in argv[1],
		   not argv[0], so we need to insert a dummy program
		   name (we use "x") at the start of the options before
		   passing them to make_argv() and then to getopt().
		*/
		dummy_command_line = make_many(char, strlen(options) + 3);
		strcpy(dummy_command_line, "x ");
		strcat(dummy_command_line, options);
		
		make_argv(dummy_command_line, &arg_str, &argv, &argc);
		oldmem(dummy_command_line);

		process_options(argc, argv);

		oldmem(arg_str);
		oldmem(argv);
	}

}

static void
process_options(int argc, char **argv)
{
	unsigned long size;
	int c;

	while ((c = getopt(argc, argv, "acC:d:D:P:pr:s:tT:xz:")) != EOF)
	{
		switch (c)
		{

		case 'a':
			benchmark_all_solns = TRUE;
			break;

		case 'c':
			check_space = TRUE;
			break;

		case 'C':
			if (sscanf(optarg, "%lu", &size) != 1)
				usage();

			pcache_size = size * 1024;

			break;

		case 'd':	
			if (streq(optarg, "b"))
				nondstackdebug = TRUE;
			else if (streq(optarg, "c"))
				calldebug    = TRUE;
			else if (streq(optarg, "d"))
				detaildebug  = TRUE;
			else if (streq(optarg, "g"))
				gotodebug    = TRUE;
			else if (streq(optarg, "G"))
#ifdef CONSERVATIVE_GC
			GC_quiet = FALSE;
#else
			fatal_error("-dG: GC not enabled");
#endif
			else if (streq(optarg, "s"))
				detstackdebug   = TRUE;
			else if (streq(optarg, "h"))
				heapdebug    = TRUE;
			else if (streq(optarg, "f"))
				finaldebug   = TRUE;
			else if (streq(optarg, "p"))
				progdebug   = TRUE;
			else if (streq(optarg, "m"))
				memdebug    = TRUE;
			else if (streq(optarg, "r"))
				sregdebug    = TRUE;
			else if (streq(optarg, "t"))
				tracedebug   = TRUE;
			else if (streq(optarg, "a")) {
				calldebug      = TRUE;
				nondstackdebug = TRUE;
				detstackdebug  = TRUE;
				heapdebug      = TRUE;
				gotodebug      = TRUE;
				sregdebug      = TRUE;
				finaldebug     = TRUE;
				tracedebug     = TRUE;
#ifdef CONSERVATIVE_GC
				GC_quiet = FALSE;
#endif
			}
			else
				usage();

			use_own_timer = FALSE;
			break;

		case 'D':
			MR_trace_enabled = TRUE;

			if (streq(optarg, "i"))
				MR_trace_handler = MR_TRACE_INTERNAL;
#ifdef	MR_USE_EXTERNAL_DEBUGGER
			else if (streq(optarg, "e"))
				MR_trace_handler = MR_TRACE_EXTERNAL;
#endif

			else
				usage();

			break;

		case 'p':
			MR_profiling = FALSE;
			break;

		case 'P':
#ifdef	MR_THREAD_SAFE
			if (sscanf(optarg, "%u", &MR_num_threads) != 1)
				usage();

			if (MR_num_threads < 1)
				usage();

#endif
			break;

		case 'r':	
			if (sscanf(optarg, "%d", &repeats) != 1)
				usage();

			break;

		case 's':
			if (sscanf(optarg+1, "%lu", &size) != 1)
				usage();

			if (optarg[0] == 'h')
				heap_size = size;
			else if (optarg[0] == 'd')
				detstack_size = size;
			else if (optarg[0] == 'n')
				nondstack_size = size;
#ifdef MR_USE_TRAIL
			else if (optarg[0] == 't')
				trail_size = size;
#endif
			else
				usage();

			break;

		case 't':	
			use_own_timer = TRUE;

			calldebug      = FALSE;
			nondstackdebug = FALSE;
			detstackdebug  = FALSE;
			heapdebug      = FALSE;
			gotodebug      = FALSE;
			sregdebug      = FALSE;
			finaldebug     = FALSE;
			break;

		case 'T':
			if (streq(optarg, "r")) {
				MR_time_profile_method = MR_profile_real_time;
			} else if (streq(optarg, "v")) {
				MR_time_profile_method = MR_profile_user_time;
			} else if (streq(optarg, "p")) {
				MR_time_profile_method =
					MR_profile_user_plus_system_time;
			} else {
				usage();
			}
			break;

		case 'x':
#ifdef CONSERVATIVE_GC
			GC_dont_gc = TRUE;
#endif

			break;

		case 'z':
			if (sscanf(optarg+1, "%lu", &size) != 1)
				usage();

			if (optarg[0] == 'h')
				heap_zone_size = size;
			else if (optarg[0] == 'd')
				detstack_zone_size = size;
			else if (optarg[0] == 'n')
				nondstack_zone_size = size;
#ifdef MR_USE_TRAIL
			else if (optarg[0] == 't')
				trail_zone_size = size;
#endif
			else
				usage();

			break;

		default:	
			usage();

		} /* end switch */
	} /* end while */
} /* end process_options() */

static void 
usage(void)
{
	printf("The MERCURY_OPTIONS environment variable "
		"contains an invalid option.\n"
		"Please refer to the Environment Variables section of "
		"the Mercury\nuser's guide for details.\n");
	fflush(stdout);
	exit(1);
} /* end usage() */

/*---------------------------------------------------------------------------*/

void 
mercury_runtime_main(void)
{
#if NUM_REAL_REGS > 0
	Word c_regs[NUM_REAL_REGS];
#endif

#if defined(MR_LOWLEVEL_DEBUG) && defined(USE_GCC_NONLOCAL_GOTOS)
	unsigned char	safety_buffer[SAFETY_BUFFER_SIZE];
#endif

	static	int	repcounter;

	/*
	** Save the C callee-save registers
	** and restore the Mercury registers
	*/
	save_regs_to_mem(c_regs);
	restore_registers();

#if defined(MR_LOWLEVEL_DEBUG) && defined(USE_GCC_NONLOCAL_GOTOS)
	/*
	** double-check to make sure that we're not corrupting
	** the C stack with these non-local gotos, by filling
	** a buffer with a known value and then later checking
	** that it still contains only this value
	*/

	global_pointer_2 = safety_buffer;	/* defeat optimization */
	memset(safety_buffer, MAGIC_MARKER_2, SAFETY_BUFFER_SIZE);
#endif

#ifdef MR_LOWLEVEL_DEBUG
  #ifndef CONSERVATIVE_GC
	MR_ENGINE(heap_zone)->max      = MR_ENGINE(heap_zone)->min;
  #endif
	MR_CONTEXT(detstack_zone)->max  = MR_CONTEXT(detstack_zone)->min;
	MR_CONTEXT(nondetstack_zone)->max = MR_CONTEXT(nondetstack_zone)->min;
#endif

	time_at_start = MR_get_user_cpu_miliseconds();
	time_at_last_stat = time_at_start;

	for (repcounter = 0; repcounter < repeats; repcounter++) {
		debugmsg0("About to call engine\n");
		call_engine(ENTRY(do_interpreter));
		debugmsg0("Returning from call_engine()\n");
	}

        if (use_own_timer) {
		time_at_finish = MR_get_user_cpu_miliseconds();
	}

#if defined(USE_GCC_NONLOCAL_GOTOS) && defined(MR_LOWLEVEL_DEBUG)
	{
		int i;

		for (i = 0; i < SAFETY_BUFFER_SIZE; i++)
			MR_assert(safety_buffer[i] == MAGIC_MARKER_2);
	}
#endif

	if (detaildebug) {
		debugregs("after final call");
	}

#ifdef MR_LOWLEVEL_DEBUG
	if (memdebug) {
		printf("\n");
  #ifndef CONSERVATIVE_GC
		printf("max heap used:      %6ld words\n",
			(long) (MR_ENGINE(heap_zone)->max
				- MR_ENGINE(heap_zone)->min));
  #endif
		printf("max detstack used:  %6ld words\n",
			(long)(MR_CONTEXT(detstack_zone)->max
			       - MR_CONTEXT(detstack_zone)->min));
		printf("max nondstack used: %6ld words\n",
			(long) (MR_CONTEXT(nondetstack_zone)->max
				- MR_CONTEXT(nondetstack_zone)->min));
	}
#endif

#ifdef MEASURE_REGISTER_USAGE
	printf("\n");
	print_register_usage_counts();
#endif

        if (use_own_timer) {
		printf("%8.3fu ",
			((double) (time_at_finish - time_at_start)) / 1000);
	}

	/*
	** Save the Mercury registers and
	** restore the C callee-save registers before returning,
	** since they may be used by the C code that called us.
	*/
	save_registers();
	restore_regs_from_mem(c_regs);

} /* end mercury_runtime_main() */

#ifdef MEASURE_REGISTER_USAGE
static void 
print_register_usage_counts(void)
{
	int	i;

	printf("register usage counts:\n");
	for (i = 0; i < MAX_RN; i++) {
		if (1 <= i && i <= ORD_RN) {
			printf("r%d", i);
		} else {
			switch (i) {

			case SI_RN:
				printf("succip");
				break;
			case HP_RN:
				printf("hp");
				break;
			case SP_RN:
				printf("sp");
				break;
			case CF_RN:
				printf("curfr");
				break;
			case MF_RN:
				printf("maxfr");
				break;
			case MR_TRAIL_PTR_RN:
				printf("MR_trail_ptr");
				break;
			case MR_TICKET_COUNTER_RN:
				printf("MR_ticket_counter");
				break;
			case MR_SOL_HP_RN:
				printf("MR_sol_hp");
				break;
			case MR_MIN_HP_REC:
				printf("MR_min_hp_rec");
				break;
			case MR_MIN_SOL_HP_REC:
				printf("MR_min_sol_hp_rec");
				break;
			case MR_GLOBAL_HP_RN:
				printf("MR_global_hp");
				break;
			default:
				printf("UNKNOWN%d", i);
				break;
			}
		}

		printf("\t%lu\n", num_uses[i]);
	} /* end for */
} /* end print_register_usage_counts() */
#endif

Define_extern_entry(do_interpreter);
Declare_label(global_success);
Declare_label(global_fail);
Declare_label(all_done);

MR_MAKE_STACK_LAYOUT_ENTRY(do_interpreter);
MR_MAKE_STACK_LAYOUT_INTERNAL_WITH_ENTRY(global_success, do_interpreter);
MR_MAKE_STACK_LAYOUT_INTERNAL_WITH_ENTRY(global_fail, do_interpreter);
MR_MAKE_STACK_LAYOUT_INTERNAL_WITH_ENTRY(all_done, do_interpreter);

BEGIN_MODULE(interpreter_module)
	init_entry(do_interpreter);
	init_label_sl(global_success);
	init_label_sl(global_fail);
	init_label_sl(all_done);
BEGIN_CODE

Define_entry(do_interpreter);
	push(MR_hp);
	push(MR_succip);
	push(MR_maxfr);
	mkframe("interpreter", 1, LABEL(global_fail));

	if (program_entry_point == NULL) {
		fatal_error("no program entry point supplied");
	}

	MR_stack_trace_bottom = LABEL(global_success);

#ifdef  PROFILE_TIME
	if (MR_profiling) MR_prof_turn_on_time_profiling();
#endif

	noprof_call(program_entry_point, LABEL(global_success));

Define_label(global_success);
#ifdef	MR_LOWLEVEL_DEBUG
	if (finaldebug) {
		save_transient_registers();
		printregs("global succeeded");
		if (detaildebug)
			dumpnondstack();
	}
#endif

	if (benchmark_all_solns)
		redo();
	else
		GOTO_LABEL(all_done);

Define_label(global_fail);
#ifdef	MR_LOWLEVEL_DEBUG
	if (finaldebug) {
		save_transient_registers();
		printregs("global failed");

		if (detaildebug)
			dumpnondstack();
	}
#endif

Define_label(all_done);

#ifdef  PROFILE_TIME
	if (MR_profiling) MR_prof_turn_off_time_profiling();
#endif

	MR_maxfr = (Word *) pop();
	MR_succip = (Code *) pop();
	MR_hp = (Word *) pop();

#ifdef MR_LOWLEVEL_DEBUG
	if (finaldebug && detaildebug) {
		save_transient_registers();
		printregs("after popping...");
	}
#endif

	proceed();
#ifndef	USE_GCC_NONLOCAL_GOTOS
	return 0;
#endif
END_MODULE

/*---------------------------------------------------------------------------*/

int
mercury_runtime_terminate(void)
{
#if NUM_REAL_REGS > 0
	Word c_regs[NUM_REAL_REGS];
#endif
	/*
	** Save the callee-save registers; we're going to start using them
	** as global registers variables now, which will clobber them,
	** and we need to preserve them, because they're callee-save,
	** and our caller may need them.
	*/
	save_regs_to_mem(c_regs);

	MR_trace_end();

	(*MR_library_finalizer)();

	MR_trace_final();

	if (MR_profiling) MR_prof_finish();

#ifdef	MR_THREAD_SAFE
	MR_exit_now = TRUE;
	pthread_cond_broadcast(MR_runqueue_cond);
#endif

	terminate_engine();

	/*
	** Restore the callee-save registers before returning,
	** since they may be used by the C code that called us.
	*/
	restore_regs_from_mem(c_regs);

	return mercury_exit_status;
}

/*---------------------------------------------------------------------------*/
void mercury_sys_init_wrapper(void); /* suppress gcc warning */
void mercury_sys_init_wrapper(void) {
	interpreter_module();
}
