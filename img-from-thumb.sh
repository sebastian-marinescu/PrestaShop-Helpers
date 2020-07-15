#!/bin/bash

MISSING_FILES=./missing-images.txt

while IFS= read -r file
do
    echo "$file"

    if test -f "..$file"; then
        echo "..$file exist"
        continue
    fi

    if test -f "..${file//.jpg/}-large_default.jpg"; then
        echo "..${file//.jpg/}-large_default.jpg exist"
        cp ..${file//.jpg/}-large_default.jpg ..${file}
        continue
    fi

    if test -f "..${file//.jpg/}-medium_default.jpg"; then
        echo "..${file//.jpg/}-medium_default.jpg exist"
        cp ..${file//.jpg/}-medium_default.jpg ..${file}
        continue
    fi

done < "$MISSING_FILES"
