#!/usr/bin/env python3
import os
import sys
import json
import subprocess
import glob
import re
from typing import List, Dict, Any

# GitHub Models API configuration
API_URL = "https://models.inference.ai.azure.com/chat/completions"
GITHUB_TOKEN = os.environ.get("COPILOT_GITHUB_TOKEN")

def log(msg: str):
    print(f"    [copilot-agent] {msg}", file=sys.stderr)

def execute_bash(command: str) -> str:
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=60)
        output = result.stdout + result.stderr
        return output if output else "[no output]"
    except subprocess.TimeoutExpired:
        return "Error: Command timed out after 60 seconds."
    except Exception as e:
        return f"Error executing bash: {str(e)}"

def execute_read(path: str) -> str:
    try:
        with open(path, 'r') as f:
            return f.read()
    except Exception as e:
        return f"Error reading file {path}: {str(e)}"

def execute_write(path: str, content: str) -> str:
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as f:
            f.write(content)
        return f"Successfully wrote to {path}"
    except Exception as e:
        return f"Error writing to file {path}: {str(e)}"

def execute_replace(path: str, old_string: str, new_string: str) -> str:
    try:
        with open(path, 'r') as f:
            content = f.read()
        if old_string not in content:
            return f"Error: old_string not found in {path}"
        if content.count(old_string) > 1:
            return f"Error: old_string is ambiguous (found {content.count(old_string)} occurrences) in {path}"
        
        new_content = content.replace(old_string, new_string)
        with open(path, 'w') as f:
            f.write(new_content)
        return f"Successfully replaced content in {path}"
    except Exception as e:
        return f"Error replacing content in {path}: {str(e)}"

def execute_grep(pattern: str, path: str = ".") -> str:
    try:
        result = subprocess.run(["grep", "-rnE", pattern, path], capture_output=True, text=True, timeout=30)
        return result.stdout if result.stdout else "[no matches]"
    except Exception as e:
        return f"Error running grep: {str(e)}"

def execute_glob(pattern: str) -> str:
    try:
        files = glob.glob(pattern, recursive=True)
        return "\n".join(files) if files else "[no matches]"
    except Exception as e:
        return f"Error running glob: {str(e)}"

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "Bash",
            "description": "Execute a bash command in the project root.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "The command to run."}
                },
                "required": ["command"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Read",
            "description": "Read the contents of a file.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "The path to the file."}
                },
                "required": ["path"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Write",
            "description": "Write content to a file, overwriting it.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "The path to the file."},
                    "content": {"type": "string", "description": "The full content to write."}
                },
                "required": ["path", "content"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Edit",
            "description": "Replace a single exact occurrence of a string in a file with another string.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "The path to the file."},
                    "old_string": {"type": "string", "description": "The exact literal text to replace."},
                    "new_string": {"type": "string", "description": "The literal text to replace it with."}
                },
                "required": ["path", "old_string", "new_string"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Grep",
            "description": "Search for a regular expression pattern in the codebase.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "The regex pattern to search for."},
                    "path": {"type": "string", "description": "Optional: The directory to search in (default: project root)."}
                },
                "required": ["pattern"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "Glob",
            "description": "Find files matching a glob pattern.",
            "parameters": {
                "type": "object",
                "properties": {
                    "pattern": {"type": "string", "description": "The glob pattern (e.g. src/**/*.ts)."}
                },
                "required": ["pattern"]
            }
        }
    }
]

def main():
    if len(sys.argv) < 3:
        print("Usage: copilot_agent.py <model> <prompt_file> [allowed_tools_csv]")
        sys.exit(1)

    model = sys.argv[1]
    prompt_file = sys.argv[2]
    allowed_tools_raw = sys.argv[3] if len(sys.argv) > 3 else ""
    allowed_tools = [t.strip().lower() for t in allowed_tools_raw.split(",")] if allowed_tools_raw else []

    if not GITHUB_TOKEN:
        print("Error: COPILOT_GITHUB_TOKEN is required", file=sys.stderr)
        sys.exit(1)

    try:
        with open(prompt_file, 'r') as f:
            prompt_content = f.read()
    except Exception as e:
        print(f"Error reading prompt file: {e}", file=sys.stderr)
        sys.exit(1)

    # Filter tools based on allowed_tools
    active_tools = []
    if allowed_tools:
        active_tools = [t for t in TOOLS if t["function"]["name"].lower() in allowed_tools]
    
    messages = [{"role": "user", "content": prompt_content}]
    
    import urllib.request
    import urllib.error

    max_turns = 20
    for turn in range(max_turns):
        data = {
            "model": model,
            "messages": messages
        }
        if active_tools:
            data["tools"] = active_tools
            data["tool_choice"] = "auto"

        req = urllib.request.Request(
            API_URL,
            data=json.dumps(data).encode('utf-8'),
            headers={
                "Authorization": f"Bearer {GITHUB_TOKEN}",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2022-11-28"
            },
            method="POST"
        )

        try:
            with urllib.request.urlopen(req) as response:
                res_data = json.loads(response.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            res_body = e.read().decode('utf-8')
            if e.code == 429:
                print(f"error: GitHub Models API rate limit (HTTP 429) - {res_body}")
                sys.exit(2) # Map to exit 2 for engine.sh fallback
            print(f"API Error ({e.code}): {res_body}", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            print(f"Unexpected Error: {e}", file=sys.stderr)
            sys.exit(1)

        choice = res_data["choices"][0]
        message = choice["message"]
        messages.append(message)

        if message.get("content"):
            # If it's the final turn or there are no tool calls, print content
            if not message.get("tool_calls"):
                print(message["content"])
                return

        if message.get("tool_calls"):
            tool_calls = message["tool_calls"]
            for tool_call in tool_calls:
                func_name = tool_call["function"]["name"]
                try:
                    args = json.loads(tool_call["function"]["arguments"])
                except Exception as e:
                    result = f"Error parsing tool arguments: {e}"
                    messages.append({
                        "role": "tool",
                        "tool_call_id": tool_call["id"],
                        "name": func_name,
                        "content": result
                    })
                    continue

                log(f"Calling tool: {func_name}({args})")
                
                if func_name == "Bash":
                    result = execute_bash(args.get("command", ""))
                elif func_name == "Read":
                    result = execute_read(args.get("path", ""))
                elif func_name == "Write":
                    result = execute_write(args.get("path", ""), args.get("content", ""))
                elif func_name == "Edit":
                    result = execute_replace(args.get("path", ""), args.get("old_string", ""), args.get("new_string", ""))
                elif func_name == "Grep":
                    result = execute_grep(args.get("pattern", ""), args.get("path", "."))
                elif func_name == "Glob":
                    result = execute_glob(args.get("pattern", ""))
                else:
                    result = f"Error: Tool {func_name} not implemented."

                messages.append({
                    "role": "tool",
                    "tool_call_id": tool_call["id"],
                    "name": func_name,
                    "content": result
                })
        else:
            # No tool calls and no more content? Should not happen often.
            break

    log("Exceeded maximum turns.")

if __name__ == "__main__":
    main()
