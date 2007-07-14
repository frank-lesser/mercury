#-----------------------------------------------------------------------------#
# Copyright (C) 1999,2001-2004, 2006-2007 The University of Melbourne.
# This file may only be copied under the terms of the GNU General
# Public Licence - see the file COPYING in the Mercury distribution.
#-----------------------------------------------------------------------------#
#
# aclocal.m4
#
# This file contains Mercury-specific autoconf tests.
#
# We ought to move most of the code in configure.in into this file...
#
#-----------------------------------------------------------------------------#
AC_DEFUN(MERCURY_CHECK_FOR_HEADERS,
[
    for mercury_cv_header in $1; do
	mercury_cv_header_define="MR_HAVE_`echo $mercury_cv_header | \
		tr abcdefghijklmnopqrstuvwxyz./ ABCDEFGHIJKLMNOPQRSTUVWXYZ__`"
	AC_CHECK_HEADER($mercury_cv_header, [
		AC_DEFINE_UNQUOTED($mercury_cv_header_define)
		eval "$mercury_cv_header_define=1"
	])
    done
])
#-----------------------------------------------------------------------------#
AC_DEFUN(MERCURY_CHECK_FOR_IEEEFP_H,
[
	MERCURY_CHECK_FOR_HEADERS(ieeefp.h)
])

AC_DEFUN(MERCURY_CHECK_FOR_IEEE_FUNC,
[
AC_REQUIRE([MERCURY_CHECK_FOR_IEEEFP_H])
AC_MSG_CHECKING(for $1 function)
mercury_cv_ieee_func_define="MR_HAVE_`echo $1 | \
	tr abcdefghijklmnopqrstuvwxyz./ ABCDEFGHIJKLMNOPQRSTUVWXYZ__`"

AC_TRY_LINK([
	#include <math.h>
#ifdef MR_HAVE_IEEEFP_H
	#include <ieeefp.h>
#endif
],[
	float f;
	$1(f);
],[mercury_cv_have_ieee_func=yes],[mercury_cv_have_ieee_func=no])

if test "$mercury_cv_have_ieee_func" = yes; then
	AC_MSG_RESULT(yes)
	AC_DEFINE_UNQUOTED($mercury_cv_ieee_func_define)
else
	AC_MSG_RESULT(no)
fi
])

#-----------------------------------------------------------------------------#
#
# Turn off MacOS's so-called "smart" C preprocessor, if present,
# since it causes lots of spurious warning messages,
# and furthermore it takes way too long and uses way too much memory
# when preprocessing the C code generated by the Mercury compiler's LLDS
# back-end.
#
AC_DEFUN(MERCURY_CHECK_CC_NEEDS_TRAD_CPP,
[
AC_REQUIRE([AC_PROG_CC])
AC_MSG_CHECKING(whether C compiler needs -no-cpp-precomp)
AC_CACHE_VAL(mercury_cv_cpp_precomp, [
	>conftest.c
	if	test "$GCC" = yes &&
		$CC -v -c conftest.c 2>&1 | \
			grep "cpp-precomp.*-smart" > /dev/null
	then
		mercury_cv_cpp_precomp=yes
	else
		mercury_cv_cpp_precomp=no
	fi
])
AC_MSG_RESULT($mercury_cv_cpp_precomp)
if test $mercury_cv_cpp_precomp = yes; then
	CC="$CC -no-cpp-precomp"
fi
])
#-----------------------------------------------------------------------------#
#
# Check whether we need to add any extra directories to the search path for
# header files, and set ALL_LOCAL_C_INCL_DIRS to the -I option(s) needed
# for this, if any.
#
# GNU C normally searches /usr/local/include by default;
# to keep things consistent, we do the same for other C compilers.
#
AC_DEFUN(MERCURY_CHECK_LOCAL_C_INCL_DIRS,
[
AC_REQUIRE([AC_PROG_CC])
AC_MSG_CHECKING(whether to pass -I/usr/local/include to C compiler)
ALL_LOCAL_C_INCL_DIRS=""
ALL_LOCAL_C_INCL_DIR_MMC_OPTS=""

if test "$GCC" = yes -o "$USING_MICROSOFT_CL_COMPILER" = yes; then
	# Don't add -I/usr/local/include, since it causes a warning
	# with gcc 3.1, and gcc already searches /usr/local/include.
	# Microsoft compilers don't understand Unix pathnames.
	AC_MSG_RESULT(no)
else
	# It's some other compiler.  We don't know if it searches
	# /usr/local/include by default, so add it.
	if test -d /usr/local/include/.; then
		AC_MSG_RESULT(yes)
		ALL_LOCAL_C_INCL_DIRS="-I/usr/local/include "
		ALL_LOCAL_C_INCL_DIR_MMC_OPTS="--c-include-directory /usr/local/include "
	else
		AC_MSG_RESULT(no)
	fi
fi
AC_SUBST(ALL_LOCAL_C_INCL_DIRS)
AC_SUBST(ALL_LOCAL_C_INCL_DIR_MMC_OPTS)
])
#-----------------------------------------------------------------------------#
#
# Set ALL_LOCAL_C_LIB_DIRS to any extra directories we need to add to the
# search path for libraries.
#
AC_DEFUN(MERCURY_CHECK_LOCAL_C_LIB_DIRS,
[
AC_MSG_CHECKING(whether to pass -L/usr/local/lib to the linker)

# Microsoft compilers don't understand Unix pathnames.
if test "$USING_MICROSOFT_CL_COMPILER" = no -a -d /usr/local/lib/.; then
	AC_MSG_RESULT(yes)
	ALL_LOCAL_C_LIB_DIRS=/usr/local/lib
	ALL_LOCAL_C_LIB_DIR_MMC_OPTS="-L/usr/local/lib -R/usr/local/lib"
else
	AC_MSG_RESULT(no)
	ALL_LOCAL_C_LIB_DIRS=
	ALL_LOCAL_C_LIB_DIR_MMC_OPTS=
fi
AC_SUBST(ALL_LOCAL_C_LIB_DIRS)
AC_SUBST(ALL_LOCAL_C_LIB_DIR_MMC_OPTS)
])

#-----------------------------------------------------------------------------#
#
# Check for readline and related header files and libraries
#
AC_DEFUN(MERCURY_CHECK_READLINE,
[
AC_ARG_WITH(readline,
[  --without-readline      Don't use the GPL'd GNU readline library],
mercury_cv_with_readline="$withval", mercury_cv_with_readline=yes)

if test "$mercury_cv_with_readline" = yes; then

	# check for the readline header files
	MERCURY_CHECK_FOR_HEADERS(readline/readline.h readline/history.h)

	# check for the libraries that readline depends on
	MERCURY_MSG('looking for termcap or curses (needed by readline)...')
	AC_CHECK_LIB(termcap, tgetent, mercury_cv_termcap_lib=-ltermcap,
	 [AC_CHECK_LIB(curses,  tgetent, mercury_cv_termcap_lib=-lcurses,
	  [AC_CHECK_LIB(ncurses, tgetent, mercury_cv_termcap_lib=-lncurses,
	   mercury_cv_termcap_lib='')])])

	# check for the readline library
	AC_CHECK_LIB(readline, readline, mercury_cv_have_readline=yes,
		mercury_cv_have_readline=no, $mercury_cv_termcap_lib)
else
	mercury_cv_have_readline=no
fi

# Now figure out whether we can use readline, and define variables according.
# Note that on most systems, we don't actually need the header files in
# order to use readline. (Ain't C grand? ;-).

if test $mercury_cv_have_readline = no; then
	TERMCAP_LIBRARY=""
	READLINE_LIBRARIES=""
	AC_DEFINE(MR_NO_USE_READLINE)
else
	TERMCAP_LIBRARY="$mercury_cv_termcap_lib"
	READLINE_LIBRARIES="-lreadline $TERMCAP_LIBRARY"
fi
AC_SUBST(TERMCAP_LIBRARY)
AC_SUBST(READLINE_LIBRARIES)

])

#-----------------------------------------------------------------------------#
#
# Microsoft.NET configuration
#
AC_DEFUN(MERCURY_CHECK_DOTNET,
[
AC_PATH_PROG(ILASM, ilasm)
AC_PATH_PROG(GACUTIL, gacutil)

AC_MSG_CHECKING(for Microsoft.NET Framework SDK)
AC_CACHE_VAL(mercury_cv_microsoft_dotnet, [
if test "$ILASM" != ""; then
	changequote(<<,>>) 
	MS_DOTNET_SDK_DIR=`expr "$ILASM" : '\(.*\)[/\\]*[bB]in[/\\]*ilasm'`
	changequote([,]) 
	mercury_cv_microsoft_dotnet="yes"
else
	MS_DOTNET_SDK_DIR=""
	mercury_cv_microsoft_dotnet="no"
fi
])
AC_MSG_RESULT($mercury_cv_microsoft_dotnet)
ILASM=`basename "$ILASM"`
GACUTIL=`basename "$GACUTIL"`

# Check for the C# (C sharp) compiler.
# cscc is the DotGNU C# compiler.
AC_PATH_PROGS(MS_CSC, csc cscc)
MS_CSC=`basename "$MS_CSC"`

# We default to the Beta 2 version of the library
mercury_cv_microsoft_dotnet_library_version=1.0.2411.0
if	test $mercury_cv_microsoft_dotnet = "yes" &&
	test "$MS_CSC" != "";
then
	AC_MSG_CHECKING(version of .NET libraries)
	cat > conftest.cs << EOF
	using System;
	using System.Reflection;
	public class version {
	    public static void Main()
	    {
		Assembly asm = Assembly.Load("mscorlib");
		AssemblyName name = asm.GetName();
		Version version = name.Version;
		Console.Write(version);
		Console.Write("\n");
	    }
	}
EOF
	if
		echo $MS_CSC conftest.cs >&AC_FD_CC 2>&1 && \
			$MS_CSC conftest.cs  >&AC_FD_CC 2>&1 && \
			./conftest > conftest.out 2>&1
	then
		mercury_cv_microsoft_dotnet_library_version=`cat conftest.out`
		AC_MSG_RESULT($mercury_cv_microsoft_dotnet_library_version)
		rm -f conftest*
	else
		rm -f conftest*
		if test "$enable_dotnet_grades" = "yes"; then
			AC_MSG_ERROR(unable to determine version)
			exit 1
		else
			AC_MSG_WARN(unable to determine version)
		fi
	fi
fi
MS_DOTNET_LIBRARY_VERSION=$mercury_cv_microsoft_dotnet_library_version

# Check for the assembly linker.
# ilalink is the DotGNU assembly linker.
AC_PATH_PROGS(MS_AL, al ilalink)
MS_AL=`basename "$MS_AL"`

AC_SUBST(ILASM)
AC_SUBST(GACUTIL)
AC_SUBST(MS_CSC)
AC_SUBST(MS_AL)
AC_SUBST(MS_DOTNET_SDK_DIR)
AC_SUBST(MS_DOTNET_LIBRARY_VERSION)
AC_SUBST(MS_VISUALCPP_DIR)
])

#-----------------------------------------------------------------------------#
#
# Java configuration
#
AC_DEFUN(MERCURY_CHECK_JAVA,
[
# jikes requires the usual Java SDK to run, so if we checked for javac first,
# then that's what we'd get. If the user has jikes installed, then that
# probably means that they want to use it, so we check for jikes before javac.
AC_PATH_PROGS(JAVAC, jikes javac gcj)
case "$JAVAC" in *gcj)
	JAVAC="$JAVAC -C" ;;
esac
AC_PATH_PROG(JAVA_INTERPRETER, java gij)
AC_PATH_PROG(JAR, jar)

AC_CACHE_VAL(mercury_cv_java, [
if test "$JAVAC" != "" -a "$JAVA_INTERPRETER" != "" -a "$JAR" != ""; then
	AC_MSG_CHECKING(if the above Java SDK works and is sufficiently recent)
	cat > conftest.java << EOF
		// This program simply retrieves the constant
		// specifying the version number of the Java SDK and
		// checks it is at least 1.2, printing "Hello, world"
		// if successful.
		public class conftest {
		    public static void main (String[[]] args) {
			float	version;
			String	strVer = System.getProperty(
					"java.specification.version");

			try {
				version = Float.valueOf(strVer).floatValue();
			}
			catch (NumberFormatException e) {
				System.out.println("ERROR: \"java." +
						"specification.version\" " +
						"constant has incorrect " +
						"format.\nGot \"" + strVer +
						"\", expected a number.");
				version = 0f;
			}

			if (version >= 1.2f) {
				System.out.println("Hello, world\n");
			} else {
				System.out.println("Nope, sorry.\n");
			}
		    }
		}
EOF
	if
		echo $JAVAC conftest.java >&AC_FD_CC 2>&1 &&
		$JAVAC conftest.java >&AC_FD_CC 2>&1 &&
		echo $JAVA_INTERPRETER conftest > conftest.out 2>&AC_FD_CC &&
		$JAVA_INTERPRETER conftest > conftest.out 2>&AC_FD_CC &&
		test "`tr -d '\015' < conftest.out`" = "Hello, world"
	then
		mercury_cv_java="yes"
	else
		mercury_cv_java="no"
	fi
	AC_MSG_RESULT($mercury_cv_java)
else
	if test "$JAVAC" = ""; then
		JAVAC="javac"
	fi
	if test "$JAVA_INTERPRETER" = ""; then
		JAVA_INTERPRETER="java"
	fi
	if test "$JAR" = ""; then
		JAR="jar"
	fi
	mercury_cv_java="no"
fi
])

AC_SUBST(JAVAC)
AC_SUBST(JAVA_INTERPRETER)
AC_SUBST(JAR)
])

#-----------------------------------------------------------------------------#
