@echo off
REM Windows wrapper for tools/workspace_status.sh — invoked by Bazel
REM via .bazelrc's `--workspace_status_command`. Two issues to dodge:
REM   (1) cmd.exe interprets `/` as a switch prefix and would strip
REM       it from `bash tools/workspace_status.sh` invoked directly.
REM   (2) msys-bash chokes on Windows backslash paths like
REM       `C:\Users\...\workspace_status.sh`.
REM Fix: pushd into the script's own directory (so bash can call it
REM by bare name without any path), then popd back. The script is
REM cwd-agnostic — its `git` calls reach the same repo regardless.
pushd "%~dp0"
bash workspace_status.sh
popd
