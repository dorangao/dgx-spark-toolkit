#!/usr/bin/env python3
"""
Test client for Qwen2.5-32B-Instruct model.
A powerful instruction-tuned model good for complex reasoning and long-form generation.

Usage:
    python test-qwen-32b.py
    python test-qwen-32b.py --prompt "Write a Python function to merge two sorted lists"
    python test-qwen-32b.py --stream --max-tokens 1024
"""

import argparse
import json
import os
import sys
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# Default endpoint
VLLM_ENDPOINT = os.environ.get("VLLM_ENDPOINT", "http://192.168.86.203:8081")
MODEL_NAME = "Qwen/Qwen2.5-32B-Instruct"


def chat_completion(prompt: str, system_prompt: str = None, stream: bool = False, max_tokens: int = 1024):
    """Send a chat completion request to vLLM."""
    url = f"{VLLM_ENDPOINT}/v1/chat/completions"
    
    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    messages.append({"role": "user", "content": prompt})
    
    payload = {
        "model": MODEL_NAME,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0.7,
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
                print(f"Assistant: {content}")
                
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
    parser = argparse.ArgumentParser(description="Test Qwen2.5-32B-Instruct model")
    parser.add_argument("--prompt", "-p", type=str, 
                        default="Explain the difference between TCP and UDP protocols, including when you would use each one.",
                        help="Prompt to send to the model")
    parser.add_argument("--system", "-sys", type=str,
                        default="You are a helpful AI assistant with expertise in technology and programming.",
                        help="System prompt")
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
    
    print(f"🧠 Qwen2.5-32B-Instruct Test Client")
    print(f"   Endpoint: {VLLM_ENDPOINT}")
    print(f"   Model: {MODEL_NAME}")
    print()
    
    if args.health:
        check_health()
        return
    
    if not check_health():
        return
    
    print()
    print(f"System: {args.system[:60]}...")
    print(f"User: {args.prompt}")
    print()
    
    chat_completion(args.prompt, system_prompt=args.system, stream=args.stream, max_tokens=args.max_tokens)


if __name__ == "__main__":
    main()
