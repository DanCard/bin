#!/bin/bash
#
# signal-remove-member.sh - Safely remove an individual from all Signal chat groups.
#
# This script:
#   1. Resolves a target identifier (Name, Phone Number, or UUID).
#   2. Formats and normalizes phone numbers (e.g. prepending + and country codes).
#   3. Scans all Signal groups to find where the target is a member.
#   4. Checks if you have admin privileges in those groups.
#   5. Defaults to DRY-RUN mode to preview changes before execution.
#
# Prerequisites: signal-cli, jq

set -euo pipefail

# --- Configuration ---
DEFAULT_ACCOUNT="+6502204874" # The default phone number of your Signal admin account
SIGNAL_CLI_BIN="/usr/local/bin/signal-cli"

# --- Variables ---
ACCOUNT="$DEFAULT_ACCOUNT"
TARGET=""
DRY_RUN=true
INTERACTIVE=true

# Disable interactive mode if stdin is not a terminal
if [ ! -t 0 ]; then
    INTERACTIVE=false
fi

show_help() {
    cat << EOF
Usage: $(basename "$0") -t TARGET [OPTIONS]

Safely remove an individual from all Signal groups where you are an admin.
Defaults to DRY-RUN mode for safety.

Required:
  -t, --target TARGET    The name, phone number, or UUID of the member to remove.

Options:
  -u, --account NUMBER   Override the admin phone number (default: $DEFAULT_ACCOUNT).
  -f, --force, --execute Disable dry-run and perform the actual removals.
  -y, --yes              Non-interactive mode (auto-resolves ambiguities or aborts).
  -h, --help             Show this help message.

Examples:
  # Preview who and where would be removed (Dry-Run):
  $(basename "$0") -t "John Doe"
  $(basename "$0") -t "6502204874"

  # Perform the actual removal (Force/Execute):
  $(basename "$0") -t "John Doe" --execute
EOF
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)
            TARGET="$2"
            shift 2
            ;;
        -u|--account)
            ACCOUNT="$2"
            shift 2
            ;;
        -f|--force|--execute)
            DRY_RUN=false
            shift
            ;;
        -y|--yes)
            INTERACTIVE=false
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'"
            show_help
            exit 1
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "Error: Missing required argument -t/--target."
    show_help
    exit 1
fi

# Ensure signal-cli and jq are installed
if ! command -v "$SIGNAL_CLI_BIN" >/dev/null; then
    echo "Error: signal-cli not found at $SIGNAL_CLI_BIN"
    exit 1
fi
if ! command -v jq >/dev/null; then
    echo "Error: jq is required but not installed."
    exit 1
fi

# --- Step 1: Format Account Number ---
# Normalize admin account number
ACCOUNT_CLEAN=$(echo "$ACCOUNT" | tr -d '[:space:]-()')
if [[ ! "$ACCOUNT_CLEAN" =~ ^\+ ]]; then
    if [ ${#ACCOUNT_CLEAN} -eq 10 ]; then
        ACCOUNT_CLEAN="+1$ACCOUNT_CLEAN"
    else
        ACCOUNT_CLEAN="+$ACCOUNT_CLEAN"
    fi
fi
ACCOUNT="$ACCOUNT_CLEAN"

# --- Step 2: Resolve Target ---
RESOLVED_PHONE=""
RESOLVED_UUID=""
RESOLVED_NAME=""

# Clean up whitespaces and formatting from target
TARGET_CLEAN=$(echo "$TARGET" | tr -d '[:space:]-()')

# Check target type
if [[ "$TARGET_CLEAN" =~ ^\+?[0-9]+$ ]]; then
    # Target looks like a phone number
    if [[ ! "$TARGET_CLEAN" =~ ^\+ ]]; then
        if [ ${#TARGET_CLEAN} -eq 10 ]; then
            TARGET_CLEAN="+1$TARGET_CLEAN"
        else
            TARGET_CLEAN="+$TARGET_CLEAN"
        fi
    fi
    RESOLVED_PHONE="$TARGET_CLEAN"
    RESOLVED_NAME="Phone: $RESOLVED_PHONE"
    echo "Identified target as phone number: $RESOLVED_PHONE"

elif [[ "$TARGET_CLEAN" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    # Target looks like a UUID
    RESOLVED_UUID="$TARGET_CLEAN"
    RESOLVED_NAME="UUID: $RESOLVED_UUID"
    echo "Identified target as UUID: $RESOLVED_UUID"

else
    # Target is treated as a contact name
    echo "Searching contacts for name matching: '$TARGET'..."
    
    if ! CONTACTS_JSON=$("$SIGNAL_CLI_BIN" -u "$ACCOUNT" --output json listContacts 2>/dev/null); then
        echo "Error: Failed to retrieve contacts list from signal-cli. Make sure your account is registered."
        exit 1
    fi
    
    # Filter matching contacts (case-insensitive, match name or profileName)
    MATCHES=$(echo "$CONTACTS_JSON" | jq -c --arg target "$TARGET" '
      .[] | select(
        (.name // "" | ascii_downcase | contains($target | ascii_downcase)) or
        (.profileName // "" | ascii_downcase | contains($target | ascii_downcase))
      )
    ')
    
    # Check match count
    if [ -z "$MATCHES" ]; then
        echo "Error: No contacts found matching '$TARGET'."
        exit 1
    fi
    
    MATCH_COUNT=$(echo "$MATCHES" | wc -l)
    
    if [ "$MATCH_COUNT" -eq 1 ]; then
        RESOLVED_PHONE=$(echo "$MATCHES" | jq -r '.number // empty')
        RESOLVED_UUID=$(echo "$MATCHES" | jq -r '.uuid // empty')
        CONTACT_NAME=$(echo "$MATCHES" | jq -r '.name // .profileName')
        RESOLVED_NAME="$CONTACT_NAME"
        
        echo "Resolved name '$TARGET' to contact: $CONTACT_NAME (Phone: ${RESOLVED_PHONE:-N/A}, UUID: ${RESOLVED_UUID:-N/A})"
    else
        echo "Multiple contacts match '$TARGET':"
        echo "$MATCHES" | jq -r '. | "  - \(.name // .profileName) (Phone: \(.number // "N/A"), UUID: \(.uuid // "N/A"))"'
        
        if [ "$INTERACTIVE" = "true" ]; then
            echo "Please select the contact (enter number 1-$MATCH_COUNT):"
            select_index=1
            mapfile -t MATCH_ARRAY < <(echo "$MATCHES")
            for i in "${!MATCH_ARRAY[@]}"; do
                name=$(echo "${MATCH_ARRAY[$i]}" | jq -r '.name // .profileName')
                phone=$(echo "${MATCH_ARRAY[$i]}" | jq -r '.number // "N/A"')
                echo "$((i+1)). $name ($phone)"
            done
            
            read -p "Selection: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$MATCH_COUNT" ]; then
                selected_match="${MATCH_ARRAY[$((choice-1))]}"
                RESOLVED_PHONE=$(echo "$selected_match" | jq -r '.number // empty')
                RESOLVED_UUID=$(echo "$selected_match" | jq -r '.uuid // empty')
                CONTACT_NAME=$(echo "$selected_match" | jq -r '.name // .profileName')
                RESOLVED_NAME="$CONTACT_NAME"
                echo "Selected: $CONTACT_NAME"
            else
                echo "Invalid selection. Aborting."
                exit 1
            fi
        else
            echo "Error: Ambiguous target name in non-interactive mode. Please specify phone number or exact UUID."
            exit 1
        fi
    fi
fi

# Ensure we resolved at least one unique identifier
if [ -z "$RESOLVED_PHONE" ] && [ -z "$RESOLVED_UUID" ]; then
    echo "Error: Could not resolve a phone number or UUID for target '$TARGET'."
    exit 1
fi

# --- Step 3: Fetch Groups ---
echo -e "\nFetching group list from Signal..."
if ! GROUPS_JSON=$("$SIGNAL_CLI_BIN" -u "$ACCOUNT" --output json listGroups 2>/dev/null); then
    echo "Error: Failed to retrieve groups list from signal-cli."
    exit 1
fi

# --- Step 4: Parse groups for membership and admin rights ---
# Output format: GROUP_ID|GROUP_NAME|IS_ADMIN
# Matches if target is a member and identifies if self is admin.
GROUPS_DATA=$(echo "$GROUPS_JSON" | jq -r \
  --arg target_phone "$RESOLVED_PHONE" \
  --arg target_uuid "$RESOLVED_UUID" \
  --arg self_phone "$ACCOUNT" '
  .[] | 
  # Check if target is a member
  (any(.members[]; .number == $target_phone or (.uuid != null and .uuid == $target_uuid))) as $is_member |
  # Check if self is admin
  (any(.admins[]; 
    if type == "string" then 
      . == $self_phone 
    else 
      .number == $self_phone
    fi
  )) as $is_admin |
  if $is_member then
    "\(.id)|\(.name // "Unnamed Group")|\($is_admin)"
  else
    empty
  fi
')

if [ -z "$GROUPS_DATA" ]; then
    echo "Target ($RESOLVED_NAME) is not a member of any Signal groups."
    exit 0
fi

# --- Step 5: Process Removals ---
# Select identifier to use for removal (prefer UUID, fall back to phone)
REMOVE_IDENTIFIER="${RESOLVED_UUID:-$RESOLVED_PHONE}"

echo -e "\nProcessing group memberships:"
echo "------------------------------------------------"

DRY_RUN_COUNT=0
REMOVED_COUNT=0
FAILED_COUNT=0
SKIP_COUNT=0

while IFS='|' read -r group_id group_name is_admin; do
    if [ "$is_admin" = "true" ]; then
        if [ "$DRY_RUN" = "true" ]; then
            echo "  [DRY-RUN] Would remove from group: '$group_name'"
            echo "            Group ID: $group_id"
            DRY_RUN_COUNT=$((DRY_RUN_COUNT + 1))
        else
            echo "  Removing from group: '$group_name' (ID: $group_id)..."
            if "$SIGNAL_CLI_BIN" -u "$ACCOUNT" updateGroup -g "$group_id" -r "$REMOVE_IDENTIFIER" >/dev/null 2>&1; then
                echo "            -> SUCCESS: Member removed."
                REMOVED_COUNT=$((REMOVED_COUNT + 1))
            else
                echo "            -> ERROR: Failed to remove member."
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
        fi
    else
        echo "  [WARNING] Cannot remove from group: '$group_name'"
        echo "            Group ID: $group_id"
        echo "            Reason: You are not a group administrator."
        SKIP_COUNT=$((SKIP_COUNT + 1))
    fi
    echo ""
done <<< "$GROUPS_DATA"

echo "------------------------------------------------"
if [ "$DRY_RUN" = "true" ]; then
    echo "Summary (Dry Run Mode):"
    echo "  - Groups target would be removed from: $DRY_RUN_COUNT"
    echo "  - Groups skipped (not an administrator): $SKIP_COUNT"
    echo -e "\nTo execute the actual removals, run the command with --execute or -f."
else
    echo "Summary:"
    echo "  - Successfully removed from groups: $REMOVED_COUNT"
    echo "  - Failed to remove from groups:       $FAILED_COUNT"
    echo "  - Groups skipped (not an admin):      $SKIP_COUNT"
fi
