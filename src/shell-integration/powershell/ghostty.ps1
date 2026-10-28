# Ghostty shell integration for PowerShell.
#
# Auto-injected by Ghostty when PowerShell is the shell (via
# `powershell -NoLogo -NoExit -Command ". '<this file>'"`). It can also be
# sourced manually from your PowerShell profile:
#
#   if ($env:GHOSTTY_RESOURCES_DIR) {
#       . "$env:GHOSTTY_RESOURCES_DIR/shell-integration/powershell/ghostty.ps1"
#   }

# Only run inside Ghostty (TERM is set to xterm-ghostty there).
if ($env:TERM -ne 'xterm-ghostty') { return }

# Guard against double-sourcing (e.g. auto-inject + profile source).
if ($global:__ghostty_shell_integration_loaded) { return }
$global:__ghostty_shell_integration_loaded = $true

# Mark the shell so Ghostty and user scripts can detect it.
if (-not $env:GHOSTTY_SHELL) { $env:GHOSTTY_SHELL = 'powershell' }

# Save the user's original prompt so its output is preserved.
$__ghostty_original_prompt = ${function:prompt}

# Send an OSC terminal control sequence.
function global:__ghostty_osc([string]$payload) {
    $esc = [char]27
    $bel = [char]7
    [Console]::Write("$esc]$payload$bel")
}

# Update the terminal title to the current directory (OSC 2).
function global:__ghostty_set_title([string]$title) {
    __ghostty_osc "2;$title"
}

# Report the current working directory (OSC 7, kitty-shell-cwd format).
function global:__ghostty_report_cwd() {
    $cwd = $PWD.ProviderPath.Replace('\', '/')
    __ghostty_osc "7;file://$cwd"
}

# Wrap the prompt: emit title/cwd updates before the user's prompt text.
function global:prompt {
    $features = $env:GHOSTTY_SHELL_FEATURES
    if ($features -like '*title*') {
        __ghostty_set_title $PWD.ProviderPath
    }
    if ($features -like '*path*') {
        __ghostty_report_cwd
    }
    if ($__ghostty_original_prompt) {
        return & $__ghostty_original_prompt
    }
    return "PS $($PWD.ProviderPath)> "
}