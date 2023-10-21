#!/bin/bash

BASH_EXE_PATH=$(dirname "$0")

# import
source $BASH_EXE_PATH/utils_helper.sh

function show_help() {
	echo "Usage: $(basename $0)"
	exit 0
}

# Display help text with -h, --help, or anything beginning with `-`
while test $# -gt 0; do
	case "$1" in
	-h | --help)
		show_help
		;;
	-*)
		show_help
		;;
	esac
	shift
done

# steps
validation
make_empty_dir
prepare_files_from_template
zip_deployment_folders

echo All done
echo "Successfully generated at $ROOT_DIR"
