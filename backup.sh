#!/bin/bash

DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" ]]; then DIR="$PWD"; fi

. "$DIR/common.sh"

PROJECTDIR="${DIR}/.."

## Script

clear

echo
echo
echo -e "${GREEN}PrestaShop Backup2GIT"
echo -e "${NC}"

echo
echo

echo -e "${NC}Changing into ${PROJECTDIR}"
cd ${PROJECTDIR}
echo "Current working directory: ${PWD}"

echo
echo -e "${ORANGE}=== Checking GIT status ==="
echo -e "${NC}"

git fetch
echo

# maybe "git diff --name-only" here?
GS=$(git status)
echo "${GS}"
echo

echo
echo -e "${ORANGE}=== Checking GIT changes ==="
echo -e "${NC}"


declare -a directories

#        array=dir;msg;commit-msg

# Theme
directories[0]='modules/iqitthemeeditor/views/css/custom_s_1.css;XXX;XXX'
directories[1]='themes/betz/mails/;XXX;XXX'
directories[2]='themes/betz/translations/;XXX;XXX'

## TODO: add other dirs

# Modules
directories[0]='modules/revsliderprestashop/uploads/;Revolution Slider assets updated;New or updated Revolution Slider assets'
directories[0]='modules/;Other modules updates;Update modules'

directories[1]='www/media/;Media files updated;New or updated media'

## TODO: go into ./img and ./
images[0]='p/;Product-Images updated;Update Product-Images'
images[0]='cms/;CMS-Images updated;Update CMS-Images'
images[0]=';Other images updated;Update other images'

# Update sub-module for images

## TODO: recursive through sub-modules

# Backup directories

for directory in "${directories[@]}"
do
    IFS=";" read -r -a arr <<< "${directory}"

    dir="${arr[0]}"
    nfo="${arr[1]}"
    msg="${arr[2]}"

    if [[ $GS == *"${dir}"* ]]; then
      echo -e "${GREEN}${nfo}"
      echo -e "${NC}"
      git add ${dir}
      git commit -m "${msg}"
      echo
    fi
done

echo
echo -e "${ORANGE}=== GIT status ==="
echo -e "${NC}"
git status

echo
echo -e "${ORANGE}=== GIT log ==="
echo -e "${NC}"
git log @{push}.. --pretty=oneline

echo
echo -e "${ORANGE}=== GIT push ==="
echo -e "${NC}"
git push

echo
echo -e "${GREEN}Everything backuped"

exit 0
