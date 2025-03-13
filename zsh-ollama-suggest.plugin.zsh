#!/usr/bin/env zsh

# zsh-openrouter-suggest - AI-powered command suggestions for Zsh using OpenRouter API
# See README.md for full documentation and configuration options.

autoload -Uz add-zle-hook-widget

# Configuration variables with defaults
typeset -g ZSH_OPENROUTER_SUGGEST_DEBUG=0    # Set to 1 to enable logging to /tmp/zsh-openrouter-suggest.log
(( ! ${+ZSH_OPENROUTER_SUGGEST_MODEL} )) && typeset -g ZSH_OPENROUTER_SUGGEST_MODEL='mistralai/ministral-3b'
(( ! ${+ZSH_OPENROUTER_SUGGEST_API_KEY} )) && typeset -g ZSH_OPENROUTER_SUGGEST_API_KEY=${OPENROUTER_API_KEY:-''}  # Use OPENROUTER_API_KEY environment variable
(( ! ${+ZSH_OPENROUTER_SUGGEST_URL} )) && typeset -g ZSH_OPENROUTER_SUGGEST_URL='https://openrouter.ai/api/v1/chat/completions'
(( ! ${+ZSH_OPENROUTER_SUGGEST_MAX_SUGGESTIONS} )) && typeset -g ZSH_OPENROUTER_SUGGEST_MAX_SUGGESTIONS=5  # Maximum number of suggestions to show
(( ! ${+ZSH_OPENROUTER_SUGGEST_HISTORY_SIZE} )) && typeset -g ZSH_OPENROUTER_SUGGEST_HISTORY_SIZE=1000  # Number of history entries to consider
(( ! ${+ZSH_OPENROUTER_SUGGEST_TEMPERATURE} )) && typeset -g ZSH_OPENROUTER_SUGGEST_TEMPERATURE=0.1  # Model temperature (0.0-1.0)
(( ! ${+ZSH_OPENROUTER_SUGGEST_DIR_LIST_SIZE} )) && typeset -g ZSH_OPENROUTER_SUGGEST_DIR_LIST_SIZE=25  # Number of directory entries to show in context
(( ! ${+ZSH_OPENROUTER_SUGGEST_MODE} )) && typeset -g ZSH_OPENROUTER_SUGGEST_MODE='manual'  # Mode: 'realtime' or 'manual'

# Internal state management
typeset -g  _openrouter_suggestions=()       # Array of current suggestions
typeset -g  _openrouter_last_command=""      # Last command that generated suggestions
typeset -g  _openrouter_suggestion_active=1  # Whether suggestions are enabled
typeset -gA _openrouter_worker_jobs          # Hash of active async workers
typeset -gi _openrouter_job_counter=0        # Counter for unique worker IDs
typeset -gi _openrouter_selected_index=0     # Currently selected suggestion index
typeset -g  _openrouter_original_buffer=""   # Original command line buffer
typeset -g  _openrouter_in_menu=0            # Whether we're in menu selection mode
typeset -ga _openrouter_current_history=()   # Current request history data

# Helper functions
_openrouter_debug() {
    # Always log to debug file regardless of debug setting
    echo "$(date '+%H:%M:%S.%3N') [$$] $1" >> /tmp/zsh-openrouter.log
}

# Function to get history entries for current request
_ollama_get_history() {
    # If history is already loaded for this request, return it
    if (( ${#_ollama_current_history} > 0 )); then
        echo "${(F)_ollama_current_history}"
        return
    fi

    # Load history for this request
    local history_data
    history_data=$(fc -ln -$ZSH_OLLAMA_SUGGEST_HISTORY_SIZE -1)
    _ollama_current_history=()
    while IFS= read -r line; do
        [[ -n "${line// }" ]] && _ollama_current_history+=("$line")
    done <<< "$history_data"
    echo "${(F)_ollama_current_history}"
}

# Function to format recent commands for JSON
_openrouter_get_recent_commands() {
    local -a history_entries
    history_entries=("${(@f)$(_openrouter_get_history)}")
    if (( ${#history_entries} > 0 )); then
        _openrouter_debug "Recent commands found"
        printf '%s\n' "${(@)history_entries[1,20]}" | jq -R -s -c 'split("\n") | map(select(length > 0))'
    else
        _openrouter_debug "No recent commands found, using empty array"
        echo '[]'
    fi
}

_openrouter_get_command_history() {
    local size=${1:-$ZSH_OPENROUTER_SUGGEST_HISTORY_SIZE}
    local pattern="$2"

    local -a history_entries
    history_entries=("${(@f)$(_openrouter_get_history)}")

    # If pattern is provided, filter entries
    if [[ -n "$pattern" ]]; then
        # Escape the pattern for use in regex
        local escaped_pattern="${pattern//\*/\\*}"
        escaped_pattern="${escaped_pattern//\[/\\[}"
        escaped_pattern="${escaped_pattern//\]/\\]}"

        # Filter entries that start with the pattern
        history_entries=( ${(M)history_entries:#${~escaped_pattern}*} )
    fi

    _openrouter_debug "Fetched ${#history_entries[@]} history entries for pattern: ${pattern:-none}"
    echo "${(F)history_entries}"
}

# Get relevant history suggestions
_openrouter_get_history_suggestions() {
    local current_input="$1"
    _openrouter_debug "Getting history suggestions for input: $current_input"

    # Get relevant history entries
    local -a matches=()
    if [[ -n "$current_input" ]]; then
        local -a history_entries
        history_entries=("${(@f)$(_openrouter_get_history)}")

        # Get exact matches (commands that start with current input)
        matches=( ${(M)history_entries:#${~current_input}*} )

        # If we have room for more suggestions, add similar matches
        if (( ${#matches} < ZSH_OPENROUTER_SUGGEST_MAX_SUGGESTIONS )); then
            # Get first word for similar matches
            local first_word="${current_input%% *}"
            local -a similar=( ${(M)history_entries:#${~first_word}*} )
            # Remove exact matches from similar matches
            similar=( ${similar:#${~current_input}*} )
            matches+=( $similar )
        fi
    fi

    _openrouter_debug "Found ${#matches[@]} history matches"
    echo "${(F)matches}"
}

_openrouter_keep_pipe() {
    : >&2  # Keep async pipe alive
}

_openrouter_display_suggestions() {
    local -a suggestions=("$@")
    local -i num_suggestions=${#suggestions[@]}

    _openrouter_debug "Display called with ${#suggestions[@]} suggestions"

    # Early return if no suggestions or not in terminal
    if (( num_suggestions == 0 )) || [[ ! -o zle ]] || [[ ! -t 1 ]]; then
        _openrouter_debug "Early return: num_suggestions=$num_suggestions, zle=$([[ -o zle ]] && echo yes || echo no), tty=$([[ -t 1 ]] && echo yes || echo no)"
        return
    fi

    # Format suggestions with arrow indicator for selection
    local output=""
    local i=1
    for suggestion in "${suggestions[@]}"; do
        if (( i == _openrouter_selected_index )); then
            output+="→ $suggestion"
        else
            output+="  $suggestion"
        fi
        (( i < num_suggestions )) && output+=$'\n'
        ((i++))
    done

    zle -M "$output"
    _openrouter_debug "Display completed"
}

# Initialize async processing
() {
    local plugin_dir="${${(%):-%x}:A:h}"
    local async_path="$plugin_dir/modules/zsh-async/async.zsh"

    if [[ ! -f "$async_path" ]]; then
        print -P "%F{red}zsh-openrouter-suggest:%f zsh-async submodule not initialized. Please run:\n    git submodule update --init --recursive"
        return 1
    fi

    source "$async_path"
    async_init
    _openrouter_debug "Plugin initialized with model: $ZSH_OPENROUTER_SUGGEST_MODEL"
}

_openrouter_async_suggestion() {
    local current_command="$1"
    local retry_count=${2:-0}  # Track retry attempts
    _openrouter_debug "Async handler started for: '$current_command' (retry: $retry_count)"

    # Clear history cache for new request
    _openrouter_current_history=()

    _openrouter_keep_pipe

    # Get history-based suggestions and properly escape them for JSON
    local history_suggestions
    history_suggestions="$(_openrouter_get_history_suggestions "$current_command")"
    history_suggestions="$(echo "$history_suggestions" | jq -R -s -c 'split("\n") | map(select(length > 0))')"

    _openrouter_debug "History suggestions: $history_suggestions"

    # Get current directory context
    local dir_context
    dir_context="Current directory: $PWD\n"
    dir_context+="Contents of current directory:\n$(ls -AFl | tail -n +2 | head -n $ZSH_OPENROUTER_SUGGEST_DIR_LIST_SIZE | awk '{
        type = substr($1,1,1);
        name = $NF;
        if (type == "d") type = "directory";
        else if (type == "l") type = "symlink";
        else if (type == "-") type = "file";
        else if (type == "p") type = "pipe";
        else if (type == "s") type = "socket";
        else if (type == "b") type = "block";
        else if (type == "c") type = "character";
        printf "- %s (%s)\n", name, type;
    }')"

    # Create system prompt for OpenRouter API
    local system_prompt="You are an expert system helping users to use a linux terminal. You will only reply with suggestions of commands. you will not interact and reply with the user in any other way. You must provide only suggested commands based on the user request."
    _openrouter_debug "System prompt: $system_prompt"

    local response
    local prompt="Suggest 3 to 5 shell commands for the user typing this in a linux terminal: $current_command"
    _openrouter_debug "User prompt: $prompt"

    # Check if API key is set
    if [[ -z "$ZSH_OPENROUTER_SUGGEST_API_KEY" ]]; then
        _openrouter_debug "OpenRouter API key is not set. Please set the OPENROUTER_API_KEY environment variable or ZSH_OPENROUTER_SUGGEST_API_KEY."
        return 1
    fi

    _openrouter_debug "Making API request to ${ZSH_OPENROUTER_SUGGEST_URL} with:"
    _openrouter_debug "- Model: $ZSH_OPENROUTER_SUGGEST_MODEL"
    _openrouter_debug "- Temperature: $ZSH_OPENROUTER_SUGGEST_TEMPERATURE"

    # Create the JSON schema for response format
    local json_schema='{"name":"commands","strict":true,"schema":{"type":"object","properties":{"commands":{"type":"array","items":{"type":"object","properties":{"command":{"type":"string","description":"The command string. Linux compatible."},"description":{"type":"string","description":"Description of what the command does"}},"required":["command","description"],"additionalProperties":false},"description":"Array of command objects"}},"required":["commands"],"additionalProperties":false}}'
    
    # Create the JSON payload for the API request
    local json_payload="
{
  \"model\": \"$ZSH_OPENROUTER_SUGGEST_MODEL\",
  \"messages\": [
    {
      \"role\": \"system\",
      \"content\": \"$system_prompt\"
    },
    {
      \"role\": \"user\",
      \"content\": \"$prompt\"
    }
  ],
  \"response_format\": {
    \"type\": \"json_schema\",
    \"json_schema\": $json_schema
  },
  \"temperature\": $ZSH_OPENROUTER_SUGGEST_TEMPERATURE
}
"

    # Pipe curl directly to jq to parse the JSON content
    response=$(echo "$json_payload" | curl -s -H "Content-Type: application/json" -H "Authorization: Bearer $ZSH_OPENROUTER_SUGGEST_API_KEY" "${ZSH_OPENROUTER_SUGGEST_URL}" -d @- 2> >(while IFS= read -r line; do _openrouter_debug "curl: $line"; done) | jq '.choices[0].message.content |= fromjson') || { _openrouter_debug "Curl request to ${ZSH_OPENROUTER_SUGGEST_URL} failed"; return 1; }

    _openrouter_debug "Raw response: $response"

    _openrouter_keep_pipe

    # Handle errors
    if [[ $? -ne 0 ]] || [[ -n "$(echo "$response" | jq -r '.error // empty')" ]]; then
        local error=$(echo "$response" | jq -r '.error // empty')
        _openrouter_debug "OpenRouter API query failed: $error"
        _openrouter_debug "Full response: $response"
        return 1
    fi
    
    # Extract the commands directly from the parsed JSON response
    local commands_json
    commands_json=$(echo "$response" | jq -r '.choices[0].message.content.commands // empty' 2>/dev/null)
    
    if [[ -z "$commands_json" || "$commands_json" == "null" ]]; then
        _openrouter_debug "Failed to parse commands JSON from content"
        return 1
    fi
    
    # Extract just the command strings and join them with newlines
    local suggestions
    suggestions=$(echo "$commands_json" | jq -r '.[].command' | grep -v '^null$')
    
    if [[ -z "$suggestions" ]]; then
        _openrouter_debug "No valid suggestions extracted for command: $current_command"
        return 1
    fi

    _openrouter_debug "Processed suggestions: '$suggestions'"
    echo "$suggestions"
    _openrouter_keep_pipe
}

_openrouter_async_callback() {
    local job_name=$1 return_code=$2 suggestions=$3

    _openrouter_keep_pipe

    _openrouter_debug "Async callback received suggestions with status $return_code: '$suggestions'"

    # Early return if no valid suggestions
    if [[ $return_code -ne 0 || -z "$suggestions" || "$suggestions" == "null" ]]; then
        _openrouter_debug "Async job $job_name failed or returned no suggestions"
        return
    fi

    # Only process if suggestions are enabled
    if [[ $_openrouter_suggestion_active -eq 1 ]]; then
        # Split suggestions into array and filter invalid ones
        local -a raw_suggestions=("${(f)suggestions}")
        _openrouter_suggestions=()

        local current_input="$BUFFER"
        local count=0
        for suggestion in $raw_suggestions; do
            # Only keep suggestions that start with the current input
            if [[ "$suggestion" = ${current_input}* ]]; then
                _openrouter_suggestions+=("$suggestion")
                ((count++))
                [[ $count -eq $ZSH_OPENROUTER_SUGGEST_MAX_SUGGESTIONS ]] && break
            else
                _openrouter_debug "Filtered out invalid suggestion: $suggestion"
            fi
        done

        _openrouter_debug "Split into array: ${#_openrouter_suggestions[@]} items: ${(j:, :)_openrouter_suggestions}"
        if (( ${#_openrouter_suggestions[@]} > 0 )); then
            _openrouter_display_suggestions "${_openrouter_suggestions[@]}"
            _openrouter_debug "Displayed ${#_openrouter_suggestions[@]} suggestions"
        fi
    fi
    _openrouter_keep_pipe
}

_openrouter_cancel_pending_jobs() {
    for job_id in ${(k)_openrouter_worker_jobs}; do
        _openrouter_debug "Stopping worker: $job_id"
        async_stop_worker "$job_id" 2>/dev/null
        async_unregister_callback "$job_id"
        unset "_openrouter_worker_jobs[$job_id]"
    done
    _openrouter_job_counter=0
}

# Widget handlers
_openrouter_self_insert() {
    zle .self-insert
    local ret=$?
    [[ "$ZSH_OPENROUTER_SUGGEST_MODE" == "realtime" ]] && _openrouter_suggest_widget
    return $ret  # Preserve original return value
}

_openrouter_backward_delete_char() {
    zle .backward-delete-char
    local ret=$?
    [[ "$ZSH_OPENROUTER_SUGGEST_MODE" == "realtime" ]] && _openrouter_suggest_widget
    return $ret  # Preserve original return value
}

_openrouter_suggest_widget() {
    _openrouter_debug "CTRL+G PRESSED: _openrouter_suggest_widget function called"
    local current_buffer="$BUFFER"
    local cursor_pos="$CURSOR"

    _openrouter_debug "Widget called with buffer: '$current_buffer', cursor: $cursor_pos"

    # Minimum input length check
    [[ ${#current_buffer} -lt 2 ]] && { _openrouter_clear_suggestions; return; }

    # Process new suggestions only if command changed
    if [[ "$current_buffer" != "$_openrouter_last_command" ]]; then
        _openrouter_debug "Command changed from '$_openrouter_last_command' to '$current_buffer'"
        _openrouter_last_command="$current_buffer"
        _openrouter_suggestions=()
        _openrouter_selected_index=0
        _openrouter_in_menu=0

        _openrouter_cancel_pending_jobs

        ((_openrouter_job_counter++))
        local job_id="worker_$$_${_openrouter_job_counter}"
        _openrouter_worker_jobs[$job_id]=1

        async_start_worker "$job_id" -n
        async_register_callback "$job_id" _openrouter_async_callback
        async_job "$job_id" _openrouter_async_suggestion "$current_buffer"
        _openrouter_debug "Started new async job $job_id for: '$current_buffer'"
    fi
}

# Navigation and menu handling
_openrouter_menu_down() {
    if (( ${#_openrouter_suggestions[@]} > 0 )); then
        if (( ! _openrouter_in_menu )); then
            _openrouter_in_menu=1
            _openrouter_original_buffer="$BUFFER"
            _openrouter_selected_index=1
        else
            # Prevent wrapping around to avoid beep
            if (( _openrouter_selected_index < ${#_openrouter_suggestions[@]} )); then
                (( _openrouter_selected_index++ ))
            fi
        fi
        BUFFER="${_openrouter_suggestions[$_openrouter_selected_index]}"
        CURSOR=${#BUFFER}
        _openrouter_display_suggestions "${_openrouter_suggestions[@]}"
        _openrouter_debug "Selected index now: $_openrouter_selected_index"
        return 0  # Explicitly return success
    else
        zle .down-line-or-history
    fi
}

_openrouter_menu_up() {
    if (( ${#_openrouter_suggestions[@]} > 0 )); then
        if (( _openrouter_in_menu )); then
            if (( _openrouter_selected_index > 1 )); then
                (( _openrouter_selected_index-- ))
                BUFFER="${_openrouter_suggestions[$_openrouter_selected_index]}"
                CURSOR=${#BUFFER}
            else
                _openrouter_selected_index=0
                _openrouter_in_menu=0
                BUFFER="$_openrouter_original_buffer"
                CURSOR=${#BUFFER}
            fi
            _openrouter_display_suggestions "${_openrouter_suggestions[@]}"
            _openrouter_debug "Selected index now: $_openrouter_selected_index"
            return 0  # Explicitly return success
        fi
    else
        zle .up-line-or-history
    fi
}

_openrouter_clear_suggestions() {
    _openrouter_debug "Clearing suggestions"
    zle -M ""
}

_openrouter_reset_state() {
    _openrouter_debug "Resetting suggestion state"
    _openrouter_suggestions=()
    _openrouter_selected_index=0
    _openrouter_in_menu=0
    _openrouter_last_command=""
    _openrouter_original_buffer=""
    zle -R
}

_openrouter_menu_accept() {
    _openrouter_debug "Menu accept called with index: $_openrouter_selected_index"
    _openrouter_clear_suggestions
    _openrouter_cancel_pending_jobs
    _openrouter_reset_state
    zle .accept-line
}

_openrouter_cleanup() {
    _openrouter_debug "Cleaning up after interrupt"
    _openrouter_clear_suggestions
    _openrouter_cancel_pending_jobs
    _openrouter_reset_state
    BUFFER=""
    CURSOR=0
    zle .send-break
    zle -R
}

_openrouter_toggle_suggestions() {
    if [[ $_openrouter_suggestion_active -eq 1 ]]; then
        _openrouter_suggestion_active=0
        _openrouter_suggestions=()
        _openrouter_selected_index=0
        _openrouter_cancel_pending_jobs
        _openrouter_debug "Suggestions disabled"
        zle -M "Suggestions disabled"
    else
        _openrouter_suggestion_active=1
        _openrouter_debug "Suggestions enabled"
        zle -M "Suggestions enabled"
    fi
    zle redisplay
}

_openrouter_toggle_mode() {
    if [[ "$ZSH_OPENROUTER_SUGGEST_MODE" == "realtime" ]]; then
        ZSH_OPENROUTER_SUGGEST_MODE="manual"
        _openrouter_clear_suggestions
        _openrouter_cancel_pending_jobs
        _openrouter_debug "Switched to manual mode"
        zle -M "Switched to manual suggestion mode"
    else
        ZSH_OPENROUTER_SUGGEST_MODE="realtime"
        _openrouter_debug "Switched to realtime mode"
        zle -M "Switched to realtime suggestion mode"
        _openrouter_suggest_widget
    fi
    zle redisplay
}

# Register widgets and key bindings
zle -N self-insert _openrouter_self_insert
zle -N backward-delete-char _openrouter_backward_delete_char
zle -N _openrouter_menu_up
zle -N _openrouter_menu_down
zle -N _openrouter_menu_accept
zle -N _openrouter_cleanup
zle -N _openrouter_toggle_mode
zle -N _openrouter_suggest_widget

bindkey '^[OA' _openrouter_menu_up     # Up arrow
bindkey '^[OB' _openrouter_menu_down   # Down arrow
bindkey '^[[A' _openrouter_menu_up     # Up arrow (alternate code)
bindkey '^[[B' _openrouter_menu_down   # Down arrow (alternate code)
bindkey '^M' _openrouter_menu_accept   # Enter
bindkey '^C' _openrouter_cleanup       # Ctrl+C
bindkey '^Xt' _openrouter_toggle_mode  # Ctrl-x t to toggle mode
bindkey '^G' _openrouter_suggest_widget  # Ctrl-g to manually trigger suggestions
_openrouter_debug "Binding Ctrl+G to _openrouter_suggest_widget"
bindkey '^?' backward-delete-char  # Backspace
