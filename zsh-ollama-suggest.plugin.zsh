#!/usr/bin/env zsh

# zsh-ollama-suggest - AI-powered command suggestions for Zsh using Ollama
# See README.md for full documentation and configuration options.

autoload -Uz add-zle-hook-widget

# Configuration variables with defaults
typeset -g ZSH_OLLAMA_SUGGEST_DEBUG=0    # Set to 1 to enable logging to /tmp/zsh-ollama-suggest.log
(( ! ${+ZSH_OLLAMA_SUGGEST_MODEL} )) && typeset -g ZSH_OLLAMA_SUGGEST_MODEL='llama3.2:3b'
(( ! ${+ZSH_OLLAMA_SUGGEST_URL} )) && typeset -g ZSH_OLLAMA_SUGGEST_URL='http://localhost:11434'
(( ! ${+ZSH_OLLAMA_SUGGEST_MAX_SUGGESTIONS} )) && typeset -g ZSH_OLLAMA_SUGGEST_MAX_SUGGESTIONS=5  # Maximum number of suggestions to show
(( ! ${+ZSH_OLLAMA_SUGGEST_HISTORY_SIZE} )) && typeset -g ZSH_OLLAMA_SUGGEST_HISTORY_SIZE=1000  # Number of history entries to consider
(( ! ${+ZSH_OLLAMA_SUGGEST_TEMPERATURE} )) && typeset -g ZSH_OLLAMA_SUGGEST_TEMPERATURE=0.1  # Model temperature (0.0-1.0)
(( ! ${+ZSH_OLLAMA_SUGGEST_DIR_LIST_SIZE} )) && typeset -g ZSH_OLLAMA_SUGGEST_DIR_LIST_SIZE=25  # Number of directory entries to show in context
(( ! ${+ZSH_OLLAMA_SUGGEST_MODE} )) && typeset -g ZSH_OLLAMA_SUGGEST_MODE='realtime'  # Mode: 'realtime' or 'manual'

# Internal state management
typeset -g  _ollama_suggestions=()       # Array of current suggestions
typeset -g  _ollama_last_command=""      # Last command that generated suggestions
typeset -g  _ollama_suggestion_active=1  # Whether suggestions are enabled
typeset -gA _ollama_worker_jobs          # Hash of active async workers
typeset -gi _ollama_job_counter=0        # Counter for unique worker IDs
typeset -gi _ollama_selected_index=0     # Currently selected suggestion index
typeset -g  _ollama_original_buffer=""   # Original command line buffer
typeset -g  _ollama_in_menu=0            # Whether we're in menu selection mode
typeset -ga _ollama_current_history=()   # Current request history data

# Helper functions
_ollama_debug() {
    [[ "$ZSH_OLLAMA_SUGGEST_DEBUG" -eq 1 ]] && echo "$(date '+%H:%M:%S.%3N') [$$] $1" >> /tmp/zsh-ollama-suggest.log
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
_ollama_get_recent_commands() {
    local -a history_entries
    history_entries=("${(@f)$(_ollama_get_history)}")
    if (( ${#history_entries} > 0 )); then
        _ollama_debug "Recent commands found"
        printf '%s\n' "${(@)history_entries[1,20]}" | jq -R -s -c 'split("\n") | map(select(length > 0))'
    else
        _ollama_debug "No recent commands found, using empty array"
        echo '[]'
    fi
}

_ollama_get_command_history() {
    local size=${1:-$ZSH_OLLAMA_SUGGEST_HISTORY_SIZE}
    local pattern="$2"

    local -a history_entries
    history_entries=("${(@f)$(_ollama_get_history)}")

    # If pattern is provided, filter entries
    if [[ -n "$pattern" ]]; then
        # Escape the pattern for use in regex
        local escaped_pattern="${pattern//\*/\\*}"
        escaped_pattern="${escaped_pattern//\[/\\[}"
        escaped_pattern="${escaped_pattern//\]/\\]}"

        # Filter entries that start with the pattern
        history_entries=( ${(M)history_entries:#${~escaped_pattern}*} )
    fi

    _ollama_debug "Fetched ${#history_entries[@]} history entries for pattern: ${pattern:-none}"
    echo "${(F)history_entries}"
}

# Get relevant history suggestions
_ollama_get_history_suggestions() {
    local current_input="$1"
    _ollama_debug "Getting history suggestions for input: $current_input"

    # Get relevant history entries
    local -a matches=()
    if [[ -n "$current_input" ]]; then
        local -a history_entries
        history_entries=("${(@f)$(_ollama_get_history)}")

        # Get exact matches (commands that start with current input)
        matches=( ${(M)history_entries:#${~current_input}*} )

        # If we have room for more suggestions, add similar matches
        if (( ${#matches} < ZSH_OLLAMA_SUGGEST_MAX_SUGGESTIONS )); then
            # Get first word for similar matches
            local first_word="${current_input%% *}"
            local -a similar=( ${(M)history_entries:#${~first_word}*} )
            # Remove exact matches from similar matches
            similar=( ${similar:#${~current_input}*} )
            matches+=( $similar )
        fi
    fi

    _ollama_debug "Found ${#matches[@]} history matches"
    echo "${(F)matches}"
}

_ollama_keep_pipe() {
    : >&2  # Keep async pipe alive
}

_ollama_display_suggestions() {
    local -a suggestions=("$@")
    local -i num_suggestions=${#suggestions[@]}

    _ollama_debug "Display called with ${#suggestions[@]} suggestions"

    # Early return if no suggestions or not in terminal
    if (( num_suggestions == 0 )) || [[ ! -o zle ]] || [[ ! -t 1 ]]; then
        _ollama_debug "Early return: num_suggestions=$num_suggestions, zle=$([[ -o zle ]] && echo yes || echo no), tty=$([[ -t 1 ]] && echo yes || echo no)"
        return
    fi

    # Format suggestions with arrow indicator for selection
    local output=""
    local i=1
    for suggestion in "${suggestions[@]}"; do
        if (( i == _ollama_selected_index )); then
            output+="→ $suggestion"
        else
            output+="  $suggestion"
        fi
        (( i < num_suggestions )) && output+=$'\n'
        ((i++))
    done

    zle -M "$output"
    _ollama_debug "Display completed"
}

# Initialize async processing
() {
    local plugin_dir="${${(%):-%x}:A:h}"
    local async_path="$plugin_dir/modules/zsh-async/async.zsh"

    if [[ ! -f "$async_path" ]]; then
        print -P "%F{red}zsh-ollama-suggest:%f zsh-async submodule not initialized. Please run:\n    git submodule update --init --recursive"
        return 1
    fi

    source "$async_path"
    async_init
    _ollama_debug "Plugin initialized with model: $ZSH_OLLAMA_SUGGEST_MODEL"
}

_ollama_async_suggestion() {
    local current_command="$1"
    local retry_count=${2:-0}  # Track retry attempts
    _ollama_debug "Async handler started for: '$current_command' (retry: $retry_count)"

    # Clear history cache for new request
    _ollama_current_history=()

    _ollama_keep_pipe

    # Get history-based suggestions and properly escape them for JSON
    local history_suggestions
    history_suggestions="$(_ollama_get_history_suggestions "$current_command")"
    history_suggestions="$(echo "$history_suggestions" | jq -R -s -c 'split("\n") | map(select(length > 0))')"

    _ollama_debug "History suggestions: $history_suggestions"

    # Get current directory context
    local dir_context
    dir_context="Current directory: $PWD\n"
    dir_context+="Contents of current directory:\n$(ls -AFl | tail -n +2 | head -n $ZSH_OLLAMA_SUGGEST_DIR_LIST_SIZE | awk '{
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

    # Create system prompt with properly escaped history context
    local system_prompt
    system_prompt=$(cat <<EOF
{
    "role": "command-line-assistant",
    "context": {
        "current_directory": "$PWD",
        "directory_contents": [$(ls -AFl | tail -n +2 | head -n $ZSH_OLLAMA_SUGGEST_DIR_LIST_SIZE | awk '{
            type = substr($1,1,1);
            name = $NF;
            if (type == "d") type = "directory";
            else if (type == "l") type = "symlink";
            else if (type == "-") type = "file";
            else if (type == "p") type = "pipe";
            else if (type == "s") type = "socket";
            else if (type == "b") type = "block";
            else if (type == "c") type = "character";
            printf "{\"name\": \"%s\", \"type\": \"%s\"}", name, type;
            if (NR < '$ZSH_OLLAMA_SUGGEST_DIR_LIST_SIZE') printf ","
        }')],
        "command_history": {
            "exact_matches": $history_suggestions,
            "recent_commands": $(_ollama_get_recent_commands),
            "current_command": "$current_command"
        }
    },
    "task": {
        "type": "command_completion",
        "input": "$current_command",
        "requirements": [
            "Complete the command based on context and history",
            "Ensure suggestions are executable in the current directory",
            "Return at most $ZSH_OLLAMA_SUGGEST_MAX_SUGGESTIONS suggestions",
            "Each suggestion must start with: $current_command",
            "Handle typos and common misspellings intelligently"
        ]
    },
    "format": {
        "type": "raw",
        "rules": [
            "Output ONLY the command suggestions",
            "One command per line",
            "NO introductory text",
            "NO explanatory text",
            "NO numbering",
            "NO bullets",
            "NO blank lines",
            "NO formatting"
        ]
    }
}
EOF
)

    _ollama_debug "System prompt: $system_prompt"

    local response
    local prompt="Complete this command: '${current_command}'. Output ONLY command suggestions, one per line, with NO additional text or formatting."
    _ollama_debug "User prompt: $prompt"

    _ollama_debug "Making API request to ${ZSH_OLLAMA_SUGGEST_URL}/api/generate with:"
    _ollama_debug "- Model: $ZSH_OLLAMA_SUGGEST_MODEL"
    _ollama_debug "- Temperature: $ZSH_OLLAMA_SUGGEST_TEMPERATURE"

    response=$(curl -v -s -H "Content-Type: application/json" "${ZSH_OLLAMA_SUGGEST_URL}/api/generate" -d @- 2> >(while IFS= read -r line; do _ollama_debug "curl: $line"; done) <<EOF
{
    "model": "$ZSH_OLLAMA_SUGGEST_MODEL",
    "system": $(echo "$system_prompt" | jq -R -s .),
    "prompt": $(echo "$prompt" | jq -R -s .),
    "temperature": $ZSH_OLLAMA_SUGGEST_TEMPERATURE,
    "stream": false
}
EOF
) || { _ollama_debug "Curl request to ${ZSH_OLLAMA_SUGGEST_URL} failed"; return 1; }

    _ollama_debug "Raw response: $response"

    _ollama_keep_pipe

    # Handle errors and model loading
    if [[ $? -ne 0 ]] || [[ -n "$(echo "$response" | jq -r '.error // empty')" ]]; then
        local error=$(echo "$response" | jq -r '.error // empty')
        _ollama_debug "Ollama query failed: $error"

        # Handle model not found error
        if [[ "$error" == *"model"*"not found"* ]]; then
            _ollama_debug "Attempting to download model: $ZSH_OLLAMA_SUGGEST_MODEL"
            local pull_response
            pull_response=$(curl -s -H "Content-Type: application/json" "${ZSH_OLLAMA_SUGGEST_URL}/api/pull" -d @- 2> >(while IFS= read -r line; do _ollama_debug "curl pull: $line"; done) <<EOF
{
    "name": "$ZSH_OLLAMA_SUGGEST_MODEL"
}
EOF
)
            _ollama_debug "Pull response: $pull_response"

            if [[ -n "$(echo "$pull_response" | jq -r '.error // empty')" ]]; then
                _ollama_debug "Model pull failed: $(echo "$pull_response" | jq -r '.error // empty')"
                return 1
            fi

            # Wait for model to be ready
            sleep 2

            # Start a new worker for the downloaded model
            local job_id="worker_$$_${_ollama_job_counter}"
            _ollama_worker_jobs[$job_id]=1

            async_start_worker "$job_id" -n
            async_register_callback "$job_id" _ollama_async_callback
            async_job "$job_id" _ollama_async_suggestion "$current_command"
            _ollama_debug "Started new worker $job_id after model download"
            return
        fi
        _ollama_debug "Full response: $response"
        return 1
    fi

    local suggestions=$(printf '%s' "$response" | jq -r '.response // empty')
    if [[ -z "$suggestions" ]]; then
        _ollama_debug "No suggestions received for command: $current_command"
        _ollama_debug "Full response: $response"
        return 1
    fi

    _ollama_debug "Processed suggestions: '$suggestions'"
    echo "$suggestions"
    _ollama_keep_pipe
}

_ollama_async_callback() {
    local job_name=$1 return_code=$2 suggestions=$3

    _ollama_keep_pipe

    _ollama_debug "Async callback received suggestions with status $return_code: '$suggestions'"

    # Early return if no valid suggestions
    if [[ $return_code -ne 0 || -z "$suggestions" || "$suggestions" == "null" ]]; then
        _ollama_debug "Async job $job_name failed or returned no suggestions"
        return
    fi

    # Only process if suggestions are enabled
    if [[ $_ollama_suggestion_active -eq 1 ]]; then
        # Split suggestions into array and filter invalid ones
        local -a raw_suggestions=("${(f)suggestions}")
        _ollama_suggestions=()

        local current_input="$BUFFER"
        local count=0
        for suggestion in $raw_suggestions; do
            # Only keep suggestions that start with the current input
            if [[ "$suggestion" = ${current_input}* ]]; then
                _ollama_suggestions+=("$suggestion")
                ((count++))
                [[ $count -eq $ZSH_OLLAMA_SUGGEST_MAX_SUGGESTIONS ]] && break
            else
                _ollama_debug "Filtered out invalid suggestion: $suggestion"
            fi
        done

        _ollama_debug "Split into array: ${#_ollama_suggestions[@]} items: ${(j:, :)_ollama_suggestions}"
        if (( ${#_ollama_suggestions[@]} > 0 )); then
            _ollama_display_suggestions "${_ollama_suggestions[@]}"
            _ollama_debug "Displayed ${#_ollama_suggestions[@]} suggestions"
        fi
    fi
    _ollama_keep_pipe
}

_ollama_cancel_pending_jobs() {
    for job_id in ${(k)_ollama_worker_jobs}; do
        _ollama_debug "Stopping worker: $job_id"
        async_stop_worker "$job_id" 2>/dev/null
        async_unregister_callback "$job_id"
        unset "_ollama_worker_jobs[$job_id]"
    done
    _ollama_job_counter=0
}

# Widget handlers
_ollama_self_insert() {
    zle .self-insert
    [[ "$ZSH_OLLAMA_SUGGEST_MODE" == "realtime" ]] && _ollama_suggest_widget
}

_ollama_backward_delete_char() {
    zle .backward-delete-char
    [[ "$ZSH_OLLAMA_SUGGEST_MODE" == "realtime" ]] && _ollama_suggest_widget
}

_ollama_suggest_widget() {
    local current_buffer="$BUFFER"
    local cursor_pos="$CURSOR"

    _ollama_debug "Widget called with buffer: '$current_buffer', cursor: $cursor_pos"

    # Minimum input length check
    [[ ${#current_buffer} -lt 2 ]] && { _ollama_clear_suggestions; return; }

    # Process new suggestions only if command changed
    if [[ "$current_buffer" != "$_ollama_last_command" ]]; then
        _ollama_debug "Command changed from '$_ollama_last_command' to '$current_buffer'"
        _ollama_last_command="$current_buffer"
        _ollama_suggestions=()
        _ollama_selected_index=0
        _ollama_in_menu=0

        _ollama_cancel_pending_jobs

        ((_ollama_job_counter++))
        local job_id="worker_$$_${_ollama_job_counter}"
        _ollama_worker_jobs[$job_id]=1

        async_start_worker "$job_id" -n
        async_register_callback "$job_id" _ollama_async_callback
        async_job "$job_id" _ollama_async_suggestion "$current_buffer"
        _ollama_debug "Started new async job $job_id for: '$current_buffer'"
    fi
}

# Navigation and menu handling
_ollama_menu_down() {
    if (( ${#_ollama_suggestions[@]} > 0 )); then
        if (( ! _ollama_in_menu )); then
            _ollama_in_menu=1
            _ollama_original_buffer="$BUFFER"
            _ollama_selected_index=1
        else
            (( _ollama_selected_index = (_ollama_selected_index % ${#_ollama_suggestions[@]}) + 1 ))
        fi
        BUFFER="${_ollama_suggestions[$_ollama_selected_index]}"
        CURSOR=${#BUFFER}
        _ollama_display_suggestions "${_ollama_suggestions[@]}"
        _ollama_debug "Selected index now: $_ollama_selected_index"
    else
        zle .down-line-or-history
    fi
}

_ollama_menu_up() {
    if (( ${#_ollama_suggestions[@]} > 0 )); then
        if (( _ollama_in_menu )); then
            if (( _ollama_selected_index > 1 )); then
                (( _ollama_selected_index-- ))
                BUFFER="${_ollama_suggestions[$_ollama_selected_index]}"
                CURSOR=${#BUFFER}
            else
                _ollama_selected_index=0
                _ollama_in_menu=0
                BUFFER="$_ollama_original_buffer"
                CURSOR=${#BUFFER}
            fi
            _ollama_display_suggestions "${_ollama_suggestions[@]}"
            _ollama_debug "Selected index now: $_ollama_selected_index"
        fi
    else
        zle .up-line-or-history
    fi
}

_ollama_clear_suggestions() {
    _ollama_debug "Clearing suggestions"
    zle -M ""
}

_ollama_reset_state() {
    _ollama_debug "Resetting suggestion state"
    _ollama_suggestions=()
    _ollama_selected_index=0
    _ollama_in_menu=0
    _ollama_last_command=""
    _ollama_original_buffer=""
    zle -R
}

_ollama_menu_accept() {
    _ollama_debug "Menu accept called with index: $_ollama_selected_index"
    _ollama_clear_suggestions
    _ollama_cancel_pending_jobs
    _ollama_reset_state
    zle .accept-line
}

_ollama_cleanup() {
    _ollama_debug "Cleaning up after interrupt"
    _ollama_clear_suggestions
    _ollama_cancel_pending_jobs
    _ollama_reset_state
    BUFFER=""
    CURSOR=0
    zle .send-break
    zle -R
}

_ollama_toggle_suggestions() {
    if [[ $_ollama_suggestion_active -eq 1 ]]; then
        _ollama_suggestion_active=0
        _ollama_suggestions=()
        _ollama_selected_index=0
        _ollama_cancel_pending_jobs
        _ollama_debug "Suggestions disabled"
        zle -M "Suggestions disabled"
    else
        _ollama_suggestion_active=1
        _ollama_debug "Suggestions enabled"
        zle -M "Suggestions enabled"
    fi
    zle redisplay
}

_ollama_toggle_mode() {
    if [[ "$ZSH_OLLAMA_SUGGEST_MODE" == "realtime" ]]; then
        ZSH_OLLAMA_SUGGEST_MODE="manual"
        _ollama_clear_suggestions
        _ollama_cancel_pending_jobs
        _ollama_debug "Switched to manual mode"
        zle -M "Switched to manual suggestion mode"
    else
        ZSH_OLLAMA_SUGGEST_MODE="realtime"
        _ollama_debug "Switched to realtime mode"
        zle -M "Switched to realtime suggestion mode"
        _ollama_suggest_widget
    fi
    zle redisplay
}

# Register widgets and key bindings
zle -N self-insert _ollama_self_insert
zle -N backward-delete-char _ollama_backward_delete_char
zle -N _ollama_menu_up
zle -N _ollama_menu_down
zle -N _ollama_menu_accept
zle -N _ollama_cleanup
zle -N _ollama_toggle_mode
zle -N _ollama_suggest_widget

bindkey '^[OA' _ollama_menu_up     # Up arrow
bindkey '^[OB' _ollama_menu_down   # Down arrow
bindkey '^[[A' _ollama_menu_up     # Up arrow (alternate code)
bindkey '^[[B' _ollama_menu_down   # Down arrow (alternate code)
bindkey '^M' _ollama_menu_accept   # Enter
bindkey '^C' _ollama_cleanup       # Ctrl+C
bindkey '^Xt' _ollama_toggle_mode  # Ctrl-x t to toggle mode
bindkey '^Xc' _ollama_suggest_widget  # Ctrl-x c to manually trigger suggestions
bindkey '^?' backward-delete-char  # Backspace
