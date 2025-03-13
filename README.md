# zsh-openrouter-suggest

Command suggestions for Zsh using [OpenRouter API](https://openrouter.ai/). Uses cloud-based LLMs to suggest commands based on your input and current directory context.

![Demo](https://github.com/user-attachments/assets/86ab6538-02f6-49d4-ac45-144df403027d)

## Features

- Suggests commands as you type
- Uses directory contents for context
- Processes suggestions asynchronously
- Two modes: realtime (as you type) or manual (on demand)
- Configurable settings for model, API key, suggestions, and context
- Structured JSON responses for better command suggestions with descriptions

## Prerequisites

- [Zsh](https://www.zsh.org/) shell
- [OpenRouter API key](https://openrouter.ai/keys)
- `git` for installation
- `curl` for API requests
- `jq` for JSON parsing
- `ls`, `awk`, `tail`, `head`, `grep` for directory and text processing
- `zsh-async` (included as submodule)

## Installation

### Using Oh My Zsh

1. Clone this repository into your Oh My Zsh custom plugins directory:
```bash
git clone --recursive https://github.com/academo/zsh-openrouter-suggest.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-openrouter-suggest
```

2. Add the plugin to your `.zshrc`:
```bash
plugins=(... zsh-openrouter-suggest)
```

### Manual Installation

1. Clone the repository with submodules:
```bash
git clone --recursive https://github.com/academo/zsh-openrouter-suggest.git
```

2. Source the plugin in your `.zshrc`:
```bash
source /path/to/zsh-openrouter-suggest/zsh-ollama-suggest.plugin.zsh
```

## Usage

1. Start typing a command (suggestions appear after 2 characters)
2. Suggestions will appear below your input:
   - Automatically in realtime mode
   - On demand with Ctrl+G in manual mode
3. Navigation:
   - Up/Down arrows to cycle through suggestions
   - Ctrl+C to clear suggestions and reset
   - Ctrl+X t to toggle between realtime/manual modes
   - Ctrl+G to manually trigger suggestions

## Configuration

The following variables can be set in your `.zshrc` before sourcing the plugin:

```zsh
# OpenRouter model to use (default: mistralai/ministral-3b)
typeset -g ZSH_OPENROUTER_SUGGEST_MODEL='mistralai/ministral-3b'

# OpenRouter API key (default: uses OPENROUTER_API_KEY environment variable)
typeset -g ZSH_OPENROUTER_SUGGEST_API_KEY='your_api_key_here'

# OpenRouter API URL (default: https://openrouter.ai/api/v1/chat/completions)
typeset -g ZSH_OPENROUTER_SUGGEST_URL='https://openrouter.ai/api/v1/chat/completions'

# Maximum number of suggestions to show (default: 5)
typeset -g ZSH_OPENROUTER_SUGGEST_MAX_SUGGESTIONS=5



# Model temperature for suggestion diversity (default: 0.1)
typeset -g ZSH_OPENROUTER_SUGGEST_TEMPERATURE=0.1

# Number of directory entries to show in context (default: 25)
typeset -g ZSH_OPENROUTER_SUGGEST_DIR_LIST_SIZE=25

# Suggestion mode: 'realtime' or 'manual' (default: manual)
typeset -g ZSH_OPENROUTER_SUGGEST_MODE='manual'

# Debug logging (default: 0)
typeset -g ZSH_OPENROUTER_SUGGEST_DEBUG=0
```

## Debugging

If you encounter issues:

1. Enable debug mode by setting `ZSH_OPENROUTER_SUGGEST_DEBUG=1` in your `.zshrc`
2. Debug logs will be written to `/tmp/zsh-openrouter.log` with millisecond timestamps
3. Ensure your OpenRouter API key is set correctly
4. Verify your model is available on OpenRouter
5. Check the log file for detailed operation tracing

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [OpenRouter](https://openrouter.ai/) for the API access to various LLMs
- [zsh-async](https://github.com/mafredri/zsh-async) for async processing
- [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) for inspiration
