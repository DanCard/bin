#!/bin/bash

# Cleanup script to delete files and directories older than 60 days
# Excludes .git directories

echo "Starting cleanup of items older than 60 days..."

# 1. Delete all old files first (excluding .git)
echo "Deleting old files..."
find . -name ".git" -prune -o -type f -mtime +60 -exec rm -v {} +

# 2. Delete all old directories (only if they are now empty and excluding .git)
echo "Deleting empty old directories..."
find . -depth ! -path "*/.git*" -type d -empty -mtime +60 -exec rmdir -v {} \;

echo "Cleanup complete."
