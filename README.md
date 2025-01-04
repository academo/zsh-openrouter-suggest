# zsh-ollama-suggest

Command suggestions for Zsh using [Ollama](https://ollama.ai/). Uses local LLMs to suggest commands based on your input, history, and current directory.

![Demo](https://github.com/user-attachments/assets/86ab6538-02f6-49d4-ac45-144df403027d)

## Features

- Suggests commands as you type
- Uses command history and directory contents for context
- Processes suggestions asynchronously
- Two modes: realtime (as you type) or manual (on demand)
- Configurable settings for model, suggestions, and context

## Prerequisites

- [Zsh](https://www.zsh.org/) shell
- [Ollama](https://ollama.ai/) installed and running
- `git` for installation
- `curl` for API requests
- `jq` for JSON parsing
- `ls`, `awk`, `tail`, `head`, `grep` for directory and text processing
- `zsh-async` (included as submodule)

## Installation

### Using Oh My Zsh

1. Clone this repository into your Oh My Zsh custom plugins directory:
```bash
git clone --recursive https://github.com/realies/zsh-ollama-suggest.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-ollama-suggest
```

2. Add the plugin to your `.zshrc`:
```bash
plugins=(... zsh-ollama-suggest)
```

### Manual Installation

1. Clone the repository with submodules:
```bash
git clone --recursive https://github.com/realies/zsh-ollama-suggest.git
```

2. Source the plugin in your `.zshrc`:
```bash
source /path/to/zsh-ollama-suggest/zsh-ollama-suggest.plugin.zsh
```

## Usage

1. Start typing a command (suggestions appear after 2 characters)
2. Suggestions will appear below your input:
   - Automatically in realtime mode
   - On demand with Ctrl+X c in manual mode
3. Navigation:
   - Up/Down arrows to cycle through suggestions
   - Ctrl+C to clear suggestions and reset
   - Ctrl+X t to toggle between realtime/manual modes
   - Ctrl+X c to manually trigger suggestions

## Configuration

The following variables can be set in your `.zshrc` before sourcing the plugin:

```zsh
# Ollama model to use (default: llama3.2:3b)
typeset -g ZSH_OLLAMA_SUGGEST_MODEL='llama3.2:3b'

# Ollama server URL (default: http://localhost:11434)
typeset -g ZSH_OLLAMA_SUGGEST_URL='http://localhost:11434'

# Maximum number of suggestions to show (default: 5)
typeset -g ZSH_OLLAMA_SUGGEST_MAX_SUGGESTIONS=5

# Number of history entries to consider (default: 1000)
typeset -g ZSH_OLLAMA_SUGGEST_HISTORY_SIZE=1000

# Model temperature for suggestion diversity (default: 0.1)
typeset -g ZSH_OLLAMA_SUGGEST_TEMPERATURE=0.1

# Number of directory entries to show in context (default: 25)
typeset -g ZSH_OLLAMA_SUGGEST_DIR_LIST_SIZE=25

# Suggestion mode: 'realtime' or 'manual' (default: realtime)
typeset -g ZSH_OLLAMA_SUGGEST_MODE='realtime'

# Debug logging (default: 0)
typeset -g ZSH_OLLAMA_SUGGEST_DEBUG=0
```

## Debugging

If you encounter issues:

1. Enable debug mode by setting `ZSH_OLLAMA_SUGGEST_DEBUG=1` in your `.zshrc`
2. Debug logs will be written to `/tmp/zsh-ollama-suggest.log` with millisecond timestamps
3. Ensure Ollama is running and accessible at your configured URL
4. Verify your model is downloaded (`ollama list`)
5. Check the log file for detailed operation tracing

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [Ollama](https://ollama.ai/) for the local LLM runtime
- [zsh-async](https://github.com/mafredri/zsh-async) for async processing
- [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) for inspiration
