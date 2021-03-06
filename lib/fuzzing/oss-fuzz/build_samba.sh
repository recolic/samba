#!/bin/sh
#
# This is not a general-purpose build script, but instead one specific
# to the Google oss-fuzz compile environment.
#
# https://google.github.io/oss-fuzz/getting-started/new-project-guide/#Requirements
#
# https://github.com/google/oss-fuzz/blob/master/infra/base-images/base-builder/README.md#provided-environment-variables
#
# This file is run by
# https://github.com/google/oss-fuzz/blob/master/projects/samba/build.sh
# which does nothing else.
#
# We have to push to oss-fuzz CFLAGS into the waf ADDITIONAL_CFLAGS
# as otherwise waf's configure fails linking the first test binary
#
# CFLAGS are supplied by the caller, eg the oss-fuzz compile command
#
# Additional arguments are passed to configure, to allow this to be
# tested in autobuild.py
#

# Ensure we give good trace info, fail right away and fail with unset
# variables
set -e
set -x
set -u

# It is critical that this script, just as the rest of Samba's GitLab
# CI docker has LANG set to en_US.utf8 (oss-fuzz fails to set this)
. /etc/default/locale
export LANG
export LC_ALL

ADDITIONAL_CFLAGS="$CFLAGS"
export ADDITIONAL_CFLAGS
CFLAGS=""
export CFLAGS
LD="$CXX"
export LD

# Use the system Python, not the OSS-Fuzz provided statically linked
# and instrumented Python, because we can't statically link.

PYTHON=/usr/bin/python3
export PYTHON

# $SANITIZER is provided by the oss-fuzz "compile" command
#
# We need to add the waf configure option as otherwise when we also
# get (eg) -fsanitize=address via the CFLAGS we will fail to link
# correctly

case "$SANITIZER" in
    address)
	SANITIZER_ARG='--address-sanitizer'
	;;
    undefined)
	SANITIZER_ARG='--undefined-sanitizer'
	;;
    coverage)
	# Thankfully clang operating as ld has no objection to the
	# cc style options, so we can just set ADDITIONAL_LDFLAGS
	# to ensure the coverage build is done, despite waf splitting
	# the compile and link phases.
	ADDITIONAL_LDFLAGS="$COVERAGE_FLAGS"
	export ADDITIONAL_LDFLAGS

	SANITIZER_ARG=''
       ;;
esac

# $LIB_FUZZING_ENGINE is provided by the oss-fuzz "compile" command
#

./configure -C --without-gettext --enable-debug --enable-developer \
            --enable-libfuzzer \
	    $SANITIZER_ARG \
	    --disable-warnings-as-errors \
	    --abi-check-disable \
	    --fuzz-target-ldflags="$LIB_FUZZING_ENGINE" \
	    --nonshared-binary=ALL \
	    "$@" \
	    LINK_CC="$CXX"

make -j

# Make a directory for the system shared libraries to be copied into
mkdir -p $OUT/lib

# We can't static link to all the system libs with waf, so copy them
# to $OUT/lib and set the rpath to point there.  This is similar to how
# firefox handles this.

for x in bin/fuzz_*
do
    cp $x $OUT/
    bin=`basename $x`

    # Copy any system libraries needed by this fuzzer to $OUT/lib
    ldd $OUT/$bin | cut -f 2 -d '>' | cut -f 1 -d \( | cut -f 2 -d  ' ' | xargs -i cp \{\} $OUT/lib/

    # Change any RPATH to RUNPATH.
    #
    # We use ld.bfd for the coverage builds, rather than the faster ld.gold.
    #
    # On Ubuntu 16.04, used for the oss-fuzz build, when linking with
    # ld.bfd the binaries get a RPATH, but builds in Ubuntu 18.04
    # ld.bfd and those using ld.gold get a RUNPATH.
    #
    # Just convert them all to RUNPATH to make the check_build.sh test
    # easier.
    chrpath -c $OUT/$bin
    # Change RUNPATH so that the copied libraries are found on the
    # runner
    chrpath -r '$ORIGIN/lib' $OUT/$bin

    # Truncate the original binary to save space
    echo -n > $x

done

# Grap the seeds dictionary from github and put the seed zips in place
# beside their executables.

wget https://gitlab.com/samba-team/samba-fuzz-seeds/-/jobs/artifacts/master/download?job=zips \
     -O seeds.zip

# We might not have unzip, but we do have python
$PYTHON -mzipfile -e seeds.zip  $OUT
rm -f seeds.zip
