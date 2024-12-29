# zsh-ollama-suggest

AI-powered command suggestions for Zsh using [Ollama](https://ollama.ai/). Get real-time, context-aware command suggestions as you type, powered by local large language models.

![Demo](https://github.com/user-attachments/assets/86ab6538-02f6-49d4-ac45-144df403027d)

## Features

- 🤖 Real-time command suggestions using local LLMs via Ollama
- ⚡️ Asynchronous processing with smart job management
- 🎯 Context-aware suggestions based on your current input
- 🎨 Interactive menu with arrow (→) selection indicator
- ⚙️ Customizable model and server settings
- 🔍 Optional debug mode with timestamped logging

## Technical Details

- Suggestions appear after typing at least 2 characters
- Maximum of 5 suggestions per query for optimal readability
- Uses temperature setting of 0.1 for consistent, deterministic suggestions
- Asynchronous processing with automatic job cancellation for outdated queries
- Smart retry mechanism for model loading (up to 3 attempts)

## Prerequisites

- [Zsh](https://www.zsh.org/) shell
- [Ollama](https://ollama.ai/) installed and running
- `curl` for API requests
- `jq` for JSON parsing
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

## Configuration

The following variables can be set in your `.zshrc` before sourcing the plugin:

```zsh
# Ollama model to use (default: llama3.2:3b)
typeset -g ZSH_OLLAMA_SUGGEST_MODEL='llama3.2:3b'

# Ollama server URL (default: http://localhost:11434)
typeset -g ZSH_OLLAMA_SUGGEST_URL='http://localhost:11434'

# Debug logging (default: 0)
typeset -g ZSH_OLLAMA_SUGGEST_DEBUG=0  # Set to 1 to enable logging
```

## Usage

1. Start typing a command (suggestions appear after 2 characters)
2. Suggestions will appear below your input
3. Navigation:
   - Up/Down arrows to cycle through suggestions
   - Enter to accept the selected suggestion
   - Backspace to modify your input
   - Ctrl+C to clear suggestions and reset
   - Ctrl+X then t to toggle suggestions on/off
4. The plugin automatically cancels outdated suggestions when you continue typing

## Key Bindings

- `↑` or `^[OA` or `^[[A` - Previous suggestion
- `↓` or `^[OB` or `^[[B` - Next suggestion
- `Enter` - Accept current suggestion
- `Ctrl+C` - Clear suggestions and reset
- `Ctrl+X t` - Toggle suggestions on/off (two separate keystrokes)
- `Backspace` - Delete character and update suggestions

## Debugging

If you encounter issues:

1. Enable debug mode by setting `ZSH_OLLAMA_SUGGEST_DEBUG=1` in your `.zshrc`
2. Debug logs will be written to `/tmp/zsh-ollama-suggest.log` with millisecond timestamps
3. Ensure Ollama is running and accessible at your configured URL
4. Verify your model is downloaded (`ollama list`)
5. Check the log file for detailed operation tracing

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [Ollama](https://ollama.ai/) for the amazing local LLM runtime
- [zsh-async](https://github.com/mafredri/zsh-async) for the asynchronous processing framework
- [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) for inspiration
