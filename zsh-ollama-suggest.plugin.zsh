#!/usr/bin/env zsh

# zsh-ollama-suggest - AI-powered command suggestions for Zsh using Ollama
# See README.md for full documentation and configuration options.

autoload -Uz add-zle-hook-widget

# Configuration variables with defaults
typeset -g ZSH_OLLAMA_SUGGEST_DEBUG=0    # Set to 1 to enable logging to /tmp/zsh-ollama-suggest.log
(( ! ${+ZSH_OLLAMA_SUGGEST_MODEL} )) && typeset -g ZSH_OLLAMA_SUGGEST_MODEL='llama3.2:3b'
(( ! ${+ZSH_OLLAMA_SUGGEST_URL} )) && typeset -g ZSH_OLLAMA_SUGGEST_URL='http://localhost:11434'

# Internal state management
typeset -g  _ollama_suggestions=()       # Array of current suggestions
typeset -g  _ollama_last_command=""      # Last command that generated suggestions
typeset -g  _ollama_suggestion_active=1  # Whether suggestions are enabled
typeset -gA _ollama_worker_jobs          # Hash of active async workers
typeset -gi _ollama_job_counter=0        # Counter for unique worker IDs
typeset -gi _ollama_selected_index=0     # Currently selected suggestion index
typeset -g  _ollama_original_buffer=""   # Original command line buffer
typeset -g  _ollama_in_menu=0            # Whether we're in menu selection mode

# Helper functions
_ollama_debug() {
    [[ "$ZSH_OLLAMA_SUGGEST_DEBUG" -eq 1 ]] && echo "$(date '+%H:%M:%S.%3N') [$$] $1" >> /tmp/zsh-ollama-suggest.log
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
    
    _ollama_keep_pipe
    
    local response
    response=$(curl -s -H "Content-Type: application/json" "${ZSH_OLLAMA_SUGGEST_URL}/api/generate" -d @- <<EOF
{
    "model": "$ZSH_OLLAMA_SUGGEST_MODEL",
    "system": "You are a command-line suggestion tool. CRITICAL RULES:\n1. Return ONLY commands, one per line, with NO explanatory text, NO numbering, NO bullets\n2. Each suggestion must be a real, executable command that exists in standard Unix/Linux systems\n3. Each suggestion must be unique - no duplicates\n4. Each suggestion must be a valid continuation of the user's current input\n5. Each suggestion must be executable in the current context\n6. Return at most 5 suggestions\n7. Suggestions should be ordered by relevance\n8. Do not include the current command in suggestions\nExample input: 'git s'. Example output: git status\ngit show\ngit stash\ngit switch\ngit sync",
    "prompt": "Complete this command: ${current_command}. Return ONLY commands, one per line. NO explanatory text, NO numbering, NO bullets. Each command must be unique and executable.",
    "temperature": 0.1,
    "stream": false
}
EOF
) || { _ollama_debug "Curl request to ${ZSH_OLLAMA_SUGGEST_URL} failed"; return 1; }
    
    _ollama_keep_pipe
    
    # Handle errors and model loading
    if [[ $? -ne 0 ]] || [[ -n "$(echo "$response" | jq -r '.error')" ]]; then
        local error=$(echo "$response" | jq -r '.error // "unknown error"')
        _ollama_debug "Ollama query failed (retry $retry_count): $error"
        if [[ "$error" == *"loading model"* ]] && (( retry_count < 3 )); then
            sleep 1
            _ollama_async_suggestion "$current_command" $((retry_count + 1))
            return
        fi
        return 1
    fi
    
    local suggestions=$(printf '%s' "$response" | jq -r '.response')
    if [[ -z "$suggestions" ]]; then
        _ollama_debug "No suggestions received for command: $current_command"
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
        _ollama_suggestions=("${(f)suggestions}")
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
    _ollama_suggest_widget
}

_ollama_backward_delete_char() {
    zle .backward-delete-char
    _ollama_suggest_widget
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
        async_job "$job_id" _ollama_async_suggestion "$current_buffer" 0
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

# Register widgets and key bindings
zle -N self-insert _ollama_self_insert
zle -N backward-delete-char _ollama_backward_delete_char
zle -N _ollama_menu_up
zle -N _ollama_menu_down
zle -N _ollama_menu_accept
zle -N _ollama_cleanup
zle -N _ollama_toggle_suggestions

bindkey '^[OA' _ollama_menu_up     # Up arrow
bindkey '^[OB' _ollama_menu_down   # Down arrow
bindkey '^[[A' _ollama_menu_up     # Up arrow (alternate code)
bindkey '^[[B' _ollama_menu_down   # Down arrow (alternate code)
bindkey '^M' _ollama_menu_accept   # Enter
bindkey '^C' _ollama_cleanup       # Ctrl+C
bindkey '^Xt' _ollama_toggle_suggestions  # Ctrl-x t to toggle
bindkey '^?' backward-delete-char  # Backspace
