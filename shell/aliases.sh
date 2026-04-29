#!/bin/bash

## List all files and exclude directories in current directory (ls -p adds trailing slash to directories | ls -x displays mul$
alias lsf="ls -apx | grep -v /"

## List only directories in current path
alias lsd="ls -d -1 */ | lolcat"

## Git rev list gist
[[ ! -f "$HOME/code/scripts/personal/git_rev_list.sh" ]] || alias git_rev_list="$HOME/code/scripts/personal/git_rev_list.sh"

## Github workflow tail gist
[[ ! -f "$HOME/code/scripts/personal/github_workflow_tail.sh" ]] || alias gh_wt="$HOME/code/scripts/personal/github_workflow_tail.sh"

[[ ! -f "$HOME/code/scripts/personal/mov2gif.sh" ]] || alias mov2gif="$HOME/code/scripts/personal/mov2gif.sh"

## Start Chrome Devtools MCP
[[ ! -f "$HOME/code/scripts/agent/chrome_mcp.sh" ]] || alias chrome_mcp="$HOME/code/scripts/agent/chrome_mcp.sh"
