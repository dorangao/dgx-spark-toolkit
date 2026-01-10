#!/usr/bin/env python3
"""
Test client for DeepSeek-Coder-V2-Lite-Instruct model.
A code-focused model optimized for programming tasks and code generation.

Usage:
    python test-deepseek-coder.py
    python test-deepseek-coder.py --prompt "Write a Python function to find prime numbers"
    python test-deepseek-coder.py --code "def fibonacci(n):" --task complete
    python test-deepseek-coder.py --code "x = [1,2,3]\nfor i in x\n  print(i)" --task fix
"""

import argparse
import json
import os
import sys
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# Default endpoint
VLLM_ENDPOINT = os.environ.get("VLLM_ENDPOINT", "http://192.168.86.203:8081")
MODEL_NAME = "deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct"


def code_completion(prompt: str, system_prompt: str = None, stream: bool = False, max_tokens: int = 1024):
    """Send a code completion request to vLLM."""
    url = f"{VLLM_ENDPOINT}/v1/chat/completions"
    
    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": prompt})
    
    payload = {
        "model": MODEL_NAME,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0.2,  # Lower temperature for code
        "stream": stream,
    }
    
    headers = {
        "Content-Type": "application/json",
    }
    
    req = Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")
    
    try:
        with urlopen(req, timeout=180) as response:
            if stream:
                print("Assistant: ", end="", flush=True)
                for line in response:
                    line = line.decode().strip()
                    if line.startswith("data: "):
                        data = line[6:]
                        if data == "[DONE]":
                            print()
                            break
                        try:
                            chunk = json.loads(data)
                            delta = chunk.get("choices", [{}])[0].get("delta", {})
                            content = delta.get("content", "")
                            print(content, end="", flush=True)
                        except json.JSONDecodeError:
                            pass
            else:
                result = json.loads(response.read().decode())
                content = result["choices"][0]["message"]["content"]
                print(f"Assistant:\n{content}")
                
                # Show usage stats
                usage = result.get("usage", {})
                print(f"\n[Tokens: {usage.get('prompt_tokens', '?')} prompt, "
                      f"{usage.get('completion_tokens', '?')} completion]")
                      
    except HTTPError as e:
        print(f"HTTP Error {e.code}: {e.reason}")
        print(e.read().decode())
        sys.exit(1)
    except URLError as e:
        print(f"Connection Error: {e.reason}")
        print(f"Is vLLM running at {VLLM_ENDPOINT}?")
        sys.exit(1)


def check_health():
    """Check if the model is loaded and healthy."""
    try:
        req = Request(f"{VLLM_ENDPOINT}/health")
        with urlopen(req, timeout=5) as response:
            print(f"✓ vLLM is healthy")
            
        # Check models
        req = Request(f"{VLLM_ENDPOINT}/v1/models")
        with urlopen(req, timeout=5) as response:
            models = json.loads(response.read().decode())
            print(f"✓ Available models:")
            for model in models.get("data", []):
                print(f"  - {model.get('id')}")
            return True
    except Exception as e:
        print(f"✗ Health check failed: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(description="Test DeepSeek-Coder-V2 model")
    parser.add_argument("--prompt", "-p", type=str,
                        help="Prompt to send to the model")
    parser.add_argument("--code", "-c", type=str,
                        help="Code snippet for completion/fixing/explanation")
    parser.add_argument("--task", "-t", type=str, choices=["complete", "fix", "explain", "review"],
                        default="complete",
                        help="Task type for --code input")
    parser.add_argument("--stream", "-s", action="store_true",
                        help="Stream the response")
    parser.add_argument("--max-tokens", "-m", type=int, default=1024,
                        help="Maximum tokens to generate")
    parser.add_argument("--endpoint", "-e", type=str, default=VLLM_ENDPOINT,
                        help="vLLM endpoint URL")
    parser.add_argument("--health", action="store_true",
                        help="Only check health status")
    
    args = parser.parse_args()
    
    # endpoint passed as parameter
    VLLM_ENDPOINT = args.endpoint
    
    print(f"💻 DeepSeek-Coder-V2-Lite Test Client")
    print(f"   Endpoint: {VLLM_ENDPOINT}")
    print(f"   Model: {MODEL_NAME}")
    print()
    
    if args.health:
        check_health()
        return
    
    if not check_health():
        return
    
    # Build prompt based on input
    if args.code:
        task_prompts = {
            "complete": f"Complete the following code:\n\n```\n{args.code}\n```",
            "fix": f"Fix the bugs in the following code:\n\n```\n{args.code}\n```",
            "explain": f"Explain what the following code does:\n\n```\n{args.code}\n```",
            "review": f"Review the following code and suggest improvements:\n\n```\n{args.code}\n```",
        }
        prompt = task_prompts.get(args.task, args.code)
    elif args.prompt:
        prompt = args.prompt
    else:
        prompt = "Write a Python function that implements binary search on a sorted list. Include docstring and type hints."
    
    system_prompt = """You are an expert programmer and code assistant. 
When writing code:
- Use clear, descriptive variable names
- Add appropriate comments and docstrings
- Follow best practices and coding standards
- Include error handling where appropriate
Provide clean, working code with explanations when needed."""

    print()
    print(f"Prompt: {prompt[:100]}{'...' if len(prompt) > 100 else ''}")
    print()
    
    code_completion(prompt, system_prompt=system_prompt, stream=args.stream, max_tokens=args.max_tokens)


if __name__ == "__main__":
    main()
