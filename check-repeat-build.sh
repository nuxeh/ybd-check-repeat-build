#!/bin/bash
# Copyright (C) 2016  Codethink Limited
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program.  If not, see <http://www.gnu.org/licenses/>.


# Repeatedly build system images and check for repeatability of
# files contained in resulting system builds using checksums, and
# analysing symbolic links.

function help() {
	echo 'Repeatedly build Baserock system images with YBD,'
        echo 'and validate the resulting system contents'
	echo
	echo 'Usage:'
	echo '    check-repeat-build.sh [-c count] [-t disable thorough checking]'
	echo '                          [-l disable link checking] [-y ybd path]'
	echo '                          system-morph-path architecture'
	echo
	echo 'Example (run from root of definitions):'
	echo '    check-repeat-build.sh systems/base-system-x86_64-generic.morph x86_64'
	exit 1
}

# Options

TARGET_COUNT=0
THOROUGH=1
LINKS=1
BUILD_EACH_TIME=0
YBD='../ybd/ybd.py'

while getopts ":rlty:n:c:" opt; do
	case $opt in
		# run count
		c) TARGET_COUNT=$OPTARG
		;;
		# disable thorough
		t) THOROUGH=0
		;;
		# disable links
		l) LINKS=0
		;;
		# rebuild
		r) BUILD_EACH_TIME=1
		;;
		# ybd path
		y) YBD=$OPTARG
		;;
		\?) echo "Invalid option -$OPTARG"; help
		;;
	esac
done

shift "$((OPTIND-1))"
if ! [ -n "$1" ] || ! [ -n "$2" ]; then help; fi

SYSTEM=$1
ARCH=$2

COUNT=0
OF="build-results-$(date | sed 's/\s/-/g;s/:/-/g')" # Output file for results
echo "Results piped to $(pwd)/$OF"

function report() {
	(
	FC=$(grep 'Run.*failed' "$OF" | wc -l)
	SC=$(grep 'Run.*succeeded' "$OF" | wc -l)
	echo "$FC tests failed"
	echo "$SC tests succeeded"
	if which bc > /dev/null && [ $COUNT -gt 0 ]; then
		if [ $FC -eq 0 ]; then
			echo "100 percent passed."
		else
			echo $(echo "scale=2; $SC*100/$FC" | bc) percent passed.; fi
		fi
	) | tee -a $OF
}

trap report EXIT

# Build a system and gather information about it
echo "Building $SYSTEM, log at \`tail -f $(pwd)/original-build\`"

$YBD $SYSTEM $ARCH | tee original-build 2>&1 > /dev/null

# 16-04-15 00:00:00 [SETUP] /src/cache/artifacts is directory for artifacts
# 16-04-15 00:00:08 [0/28/125] [base-system-x86_64-generic] WARNING: overlapping path /sbin/halt
# 16-04-15 00:00:38 [1/28/125] [base-system-x86_64-generic] Cached 1504286720 bytes d0783c3f0bb26c630f85c33fac06766f as base-system-x86_64-generic.e94e0734c094baced9f5af1909b56e5b86dc4ff4700827b2762007edfd6223eb

ARTIFACT_DIR=$(sed 's/^[[:digit:]]*//' original-build | awk '/is directory for artifacts/ {print $4}')
SYS_NAME=$(basename "$SYSTEM" .morph)
SYS_ARTIFACT=$(awk "/.*Cached.*$SYS_NAME.*/ {print \$NF}" original-build)

if [ "$SYS_ARTIFACT" == "" ]; then
	echo "No system artifact found. You may need to clear the YBD cache directory to rebuild."
	exit 1
fi

OVERLAPS=$(awk '/WARNING: overlapping path/ {print $NF}' original-build)

SYS_ARTIFACT_PATH="$ARTIFACT_DIR/$SYS_ARTIFACT"
SYS_UNPACKED="$SYS_ARTIFACT_PATH/$SYS_ARTIFACT.unpacked"

# Collect data from original system for comparison
echo "Overlapping files:"
echo -n > original-md5sums
for o in $OVERLAPS; do
	echo "$o"
	FILE=$(file "$SYS_UNPACKED$o" | awk '/symbolic link/ {print $NF}')
	if [ "$FILE" == ""  ]; then
		md5sum "$SYS_UNPACKED/$o" >> original-md5sums
	else
		echo "Following symbolic link $o -> $FILE"
		if ! md5sum "$SYS_UNPACKED/$FILE" >> original-md5sums 2> /dev/null; then
			# Relative symlink path
			LINKPATH=$(echo "$o" | sed 's@\(^.*\)/.*@\1@')
			md5sum "$SYS_UNPACKED/$LINKPATH/$FILE" >> original-md5sums
		fi
	fi
done

echo -n > original-md5sums-all-reg-files
if [ $THOROUGH -eq 1 ]; then
	# Checksum all files
	echo "Generating checksums for all regular files..."
	# Exclude ldconfig cache, regenerated each time by ldconfig
	find "$SYS_UNPACKED" -type f \
		-not -regex '.*/var/cache/ldconfig/aux-cache' \
		-exec md5sum "{}" + > original-md5sums-all-reg-files
	echo "Evaluated $(wc -l original-md5sums-all-reg-files | awk '{print $1}') files."
fi

echo -n > original-links
if [ $LINKS -eq 1 ]; then
	echo "Finding symbolic links..."
	find "$SYS_UNPACKED" -exec file "{}" + | grep 'symbolic link to' > original-links
	echo "Evaluated $(wc -l original-links | awk '{print $1}') symbolic links"
fi

# Run tests:
STATUS=0
echo -n > $OF
while true; do

	# Delete system artifact
	echo "Deleting system artifact: $SYS_ARTIFACT_PATH"
	rm -rf $SYS_ARTIFACT_PATH

	# Rebuild
	BOF="build-$COUNT"
	echo "Run $COUNT / $TARGET_COUNT: Rebuilding $SYSTEM, log at \`tail -f $(pwd)/$BOF\`" | tee -a $OF

	$YBD $SYSTEM $ARCH | tee $BOF 2>&1 > /dev/null

	(echo "Overlaps:"
	 awk '/WARNING: overlapping path/ {print $NF}' $BOF) | tee -a $OF

	# Test
	PASS=1

	if ! md5sum -c original-md5sums &> md5-result; then
		# Check overlapping files
		PASS=0
	fi

	if [ $THOROUGH -eq 1 ]; then
		# Check all files
		if ! md5sum -c original-md5sums-all-reg-files &> md5-result-all; then
			PASS=0
		fi
	fi

	if [ $LINKS -eq 1 ]; then
		# Check symbolic link destination paths
		echo -n > link-result
		while read entry; do
			FILE=$(echo "$entry" | awk '{print $1}' | sed 's/\(.*\):/\1/')
			NEW=$(file $FILE | awk '{print $NF}')
			ORIG=$(echo $entry | awk '{print $NF}')
			if [ "$ORIG" != "$NEW" ]; then
				SHORTFILE=$(echo $FILE | sed 's/$SYS_UNPACKED//')
				echo "FAILED: $SHORTFILE: orig: $ORIG new: $NEW" >> link-result
				PASS=0
			fi
		done < original-links
	fi

	# Status
	if [ $PASS -eq 0 ]; then
		(
		echo "Run $COUNT failed"
		echo "Result:"
		echo "Overlapping files:"
		cat md5-result | egrep 'FAILED|WARNING:'
		echo "$(cat md5-result | egrep 'FAILED' | wc -l ) files failed checksum"
		if [ $THOROUGH -eq 1 ]; then
			echo 'All files:'
			cat md5-result-all | egrep 'FAILED|WARNING:'
			echo "$(cat md5-result-all | egrep 'FAILED' | wc -l ) files failed checksum"
		else
			echo 'All files test not run'
		fi
		if [ $LINKS -eq 1 ]; then
			echo "Symbolic links:"
			cat link-result
			echo "$(cat link-result | wc -l ) link destinations differ"
		else
			echo 'Links test not run'
		fi
		) | tee -a $OF
		STATUS=1
	else
		echo "Run $COUNT succeeded" | tee -a $OF
	fi

	COUNT=$(($COUNT+1))
	if [ $COUNT -eq $TARGET_COUNT ]; then exit $STATUS; fi

done
