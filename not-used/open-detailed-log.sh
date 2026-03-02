#!/bin/bash
# Open the most recently created detailed-*.log file in geany

# Check if current directory is named "logs"
CURRENT_DIR=$(basename "$PWD")

if [ "$CURRENT_DIR" = "logs" ]; then
    # We're in the logs directory
    LATEST_FILE=$(ls -t detailed-*.log 2>/dev/null | head -n 1)
    SEARCH_DIR="current directory (logs)"
elif [ -d "logs" ]; then
    # Look in logs subdirectory
    LATEST_FILE=$(ls -t logs/detailed-*.log 2>/dev/null | head -n 1)
    SEARCH_DIR="logs/"
else
    echo "No logs directory found"
    exit 1
fi

if [ -z "$LATEST_FILE" ]; then
    echo "No detailed-*.log files found in $SEARCH_DIR"
    exit 1
fi

echo "Opening: $LATEST_FILE"
geany "$LATEST_FILE"
