#!/bin/bash

# Store the last checked directory to avoid redundant `.nvmrc` checks
LAST_NVM_DIR=""

# Load the correct Node.js version based on the `.nvmrc` file
load_nvmrc() {
    # Get the current working directory
    local current_dir="$(pwd)"

    # Check if the directory is the same as the last checked directory
    if [[ "$current_dir" == "$LAST_NVM_DIR" ]]; then
        return 0 # Exit early if already checked
    fi

    # Update the last checked directory
    LAST_NVM_DIR="$current_dir"

    # Check if an `.nvmrc` file exists in the current directory
    if [[ -f .nvmrc ]]; then
        # Read the Node.js version specified in the `.nvmrc` file
        local nvmrc_node_version
        nvmrc_node_version=$(cat .nvmrc)

        # Compare the `.nvmrc` version with the currently active version
        if [[ "$nvmrc_node_version" != "$(nvm current)" ]]; then
            # Use the version specified in `.nvmrc`, or install it if not available
            nvm use || nvm install
        fi
    elif [[ "$(nvm current)" != "$(nvm alias default 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')" ]]; then
        # No `.nvmrc` found — revert to default version if not already on it
        nvm use default --silent
    fi
}

# Shell-specific hooks to trigger `load_nvmrc` on directory change

# For zsh users
if [[ -n "$ZSH_VERSION" ]]; then
    # Load the zsh hook functionality
    autoload -U add-zsh-hook

    # Add a hook that triggers `load_nvmrc` whenever the directory changes
    add-zsh-hook chpwd load_nvmrc

    # Run `load_nvmrc` immediately to cover the initial shell session directory
    load_nvmrc

# For bash users
elif [[ -n "$BASH_VERSION" ]]; then
    # Define a function to run `load_nvmrc` as part of the bash prompt command
    cd_nvm_use() {
        load_nvmrc
    }

    # Append the `cd_nvm_use` function to the `PROMPT_COMMAND` to ensure it runs
    # every time the prompt is refreshed (e.g., after changing directories)
    PROMPT_COMMAND="cd_nvm_use; $PROMPT_COMMAND"
fi

