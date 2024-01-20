#!/bin/bash

if [ $# -eq 0 ]; then
    echo "Usage: $0 <directory>"
    exit 1
fi

search_directory="$1"

find "$search_directory" -type f -name '*' -print0 | while IFS= read -r -d '' file; do
    while IFS= read -r line; do
        if [ ${#line} -gt 80 ]; then
            echo -e "\n$file:$(grep -n "$line" "$file" | cut -d':' -f1):$(grep -n "$line" "$file" | cut -d':' -f2) - Line too long:"
            echo "$line"
        fi
    done <"$file"
done