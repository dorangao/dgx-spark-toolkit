#!/usr/bin/env python3
"""
Test client for Nemotron-3 Nano 30B model.
A reasoning-focused model good for instruction following and chain-of-thought.

Usage:
    python test-nemotron-nano.py
    python test-nemotron-nano.py --prompt "Explain quantum computing"
    python test-nemotron-nano.py --stream
"""

import argparse
import json
import os
import sys
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# Default endpoint
VLLM_ENDPOINT = os.environ.get("VLLM_ENDPOINT", "http://192.168.86.203:8081")
MODEL_NAME = "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16"


def chat_completion(prompt: str, stream: bool = False, max_tokens: int = 512):
    """Send a chat completion request to vLLM."""
    url = f"{VLLM_ENDPOINT}/v1/chat/completions"
    
    payload = {
        "model": MODEL_NAME,
        "messages": [
            {"role": "system", "content": "You are a helpful AI assistant."},
            {"role": "user", "content": prompt}
        ],
        "max_tokens": max_tokens,
        "temperature": 0.7,
        "stream": stream,
    }
    
    headers = {
        "Content-Type": "application/json",
    }
    
    req = Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")
    
    try:
        with urlopen(req, timeout=120) as response:
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
    parser = argparse.ArgumentParser(description="Test Nemotron-3 Nano 30B model")
    parser.add_argument("--prompt", "-p", type=str, 
                        default="Explain the concept of recursion in programming with a simple example.",
                        help="Prompt to send to the model")
    parser.add_argument("--stream", "-s", action="store_true",
                        help="Stream the response")
    parser.add_argument("--max-tokens", "-m", type=int, default=512,
                        help="Maximum tokens to generate")
    parser.add_argument("--endpoint", "-e", type=str, default=VLLM_ENDPOINT,
                        help="vLLM endpoint URL")
    parser.add_argument("--health", action="store_true",
                        help="Only check health status")
    
    args = parser.parse_args()
    
    # endpoint passed as parameter
    VLLM_ENDPOINT = args.endpoint
    
    print(f"🚀 Nemotron-3 Nano 30B Test Client")
    print(f"   Endpoint: {VLLM_ENDPOINT}")
    print(f"   Model: {MODEL_NAME}")
    print()
    
    if args.health:
        check_health()
        return
    
    if not check_health():
        return
    
    print()
    print(f"User: {args.prompt}")
    print()
    
    chat_completion(args.prompt, stream=args.stream, max_tokens=args.max_tokens)


if __name__ == "__main__":
    main()
