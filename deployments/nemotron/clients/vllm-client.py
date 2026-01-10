#!/usr/bin/env python3
"""
Universal vLLM client that works with any deployed model.
Auto-detects the loaded model and provides appropriate testing.

Usage:
    python vllm-client.py                           # Interactive mode
    python vllm-client.py --prompt "Hello"          # Single prompt
    python vllm-client.py --chat                    # Multi-turn chat
    python vllm-client.py --image path/to/img.jpg   # Vision (if supported)
    python vllm-client.py --benchmark               # Run benchmark
"""

import argparse
import base64
import json
import os
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# Default endpoint
VLLM_ENDPOINT = os.environ.get("VLLM_ENDPOINT", "http://192.168.86.203:8081")


class VLLMClient:
    def __init__(self, endpoint: str):
        self.endpoint = endpoint.rstrip("/")
        self.model_name = None
        self.model_info = None
        
    def health_check(self) -> bool:
        """Check if vLLM is healthy."""
        try:
            req = Request(f"{self.endpoint}/health")
            with urlopen(req, timeout=5) as response:
                return response.status == 200
        except Exception:
            return False
    
    def get_models(self) -> list:
        """Get list of available models."""
        try:
            req = Request(f"{self.endpoint}/v1/models")
            with urlopen(req, timeout=5) as response:
                data = json.loads(response.read().decode())
                return data.get("data", [])
        except Exception:
            return []
    
    def detect_model(self) -> str:
        """Detect the currently loaded model."""
        models = self.get_models()
        if models:
            self.model_name = models[0].get("id", "unknown")
            self.model_info = models[0]
            return self.model_name
        return None
    
    def is_vision_model(self) -> bool:
        """Check if the model supports vision."""
        if not self.model_name:
            return False
        vision_indicators = ["image", "vision", "vl", "qwen-vl", "llava"]
        return any(ind in self.model_name.lower() for ind in vision_indicators)
    
    def chat(self, messages: list, stream: bool = False, max_tokens: int = 1024, 
             temperature: float = 0.7) -> str:
        """Send chat completion request."""
        url = f"{self.endpoint}/v1/chat/completions"
        
        payload = {
            "model": self.model_name,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": stream,
        }
        
        headers = {"Content-Type": "application/json"}
        req = Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")
        
        with urlopen(req, timeout=300) as response:
            if stream:
                result = []
                for line in response:
                    line = line.decode().strip()
                    if line.startswith("data: "):
                        data = line[6:]
                        if data == "[DONE]":
                            break
                        try:
                            chunk = json.loads(data)
                            delta = chunk.get("choices", [{}])[0].get("delta", {})
                            content = delta.get("content", "")
                            if content:
                                print(content, end="", flush=True)
                                result.append(content)
                        except json.JSONDecodeError:
                            pass
                print()
                return "".join(result)
            else:
                result = json.loads(response.read().decode())
                return result["choices"][0]["message"]["content"]
    
    def vision_chat(self, image_source: str, prompt: str, max_tokens: int = 512) -> str:
        """Send vision chat request."""
        url = f"{self.endpoint}/v1/chat/completions"
        
        # Handle image source
        if image_source.startswith(("http://", "https://")):
            image_content = {
                "type": "image_url",
                "image_url": {"url": image_source}
            }
        else:
            # Local file
            if not os.path.exists(image_source):
                raise FileNotFoundError(f"Image not found: {image_source}")
            
            ext = Path(image_source).suffix.lower()
            mime_types = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", 
                         ".png": "image/png", ".gif": "image/gif", ".webp": "image/webp"}
            mime_type = mime_types.get(ext, "image/jpeg")
            
            with open(image_source, "rb") as f:
                base64_data = base64.b64encode(f.read()).decode()
            
            image_content = {
                "type": "image_url",
                "image_url": {"url": f"data:{mime_type};base64,{base64_data}"}
            }
        
        payload = {
            "model": self.model_name,
            "messages": [{
                "role": "user",
                "content": [image_content, {"type": "text", "text": prompt}]
            }],
            "max_tokens": max_tokens,
            "temperature": 0.7,
        }
        
        headers = {"Content-Type": "application/json"}
        req = Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")
        
        with urlopen(req, timeout=300) as response:
            result = json.loads(response.read().decode())
            return result["choices"][0]["message"]["content"]
    
    def benchmark(self, prompt: str = None, num_requests: int = 5) -> dict:
        """Run a simple benchmark."""
        if not prompt:
            prompt = "Write a short paragraph about artificial intelligence."
        
        messages = [{"role": "user", "content": prompt}]
        
        print(f"Running benchmark with {num_requests} requests...")
        times = []
        tokens = []
        
        for i in range(num_requests):
            start = time.time()
            try:
                url = f"{self.endpoint}/v1/chat/completions"
                payload = {
                    "model": self.model_name,
                    "messages": messages,
                    "max_tokens": 256,
                    "temperature": 0.7,
                }
                headers = {"Content-Type": "application/json"}
                req = Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")
                
                with urlopen(req, timeout=120) as response:
                    result = json.loads(response.read().decode())
                    elapsed = time.time() - start
                    times.append(elapsed)
                    usage = result.get("usage", {})
                    tokens.append(usage.get("completion_tokens", 0))
                    print(f"  Request {i+1}: {elapsed:.2f}s, {tokens[-1]} tokens")
            except Exception as e:
                print(f"  Request {i+1}: Failed - {e}")
        
        if times:
            avg_time = sum(times) / len(times)
            avg_tokens = sum(tokens) / len(tokens) if tokens else 0
            tokens_per_sec = avg_tokens / avg_time if avg_time > 0 else 0
            
            return {
                "avg_latency": avg_time,
                "avg_tokens": avg_tokens,
                "tokens_per_second": tokens_per_sec,
                "total_requests": len(times),
            }
        return {}


def interactive_chat(client: VLLMClient, system_prompt: str = None):
    """Run interactive chat session."""
    print("\n💬 Interactive Chat Mode")
    print("   Type 'quit' or 'exit' to end")
    print("   Type 'clear' to reset conversation")
    print("-" * 50)
    
    messages = []
    if system_prompt:
        messages.append({"role": "system", "content": system_prompt})
    
    while True:
        try:
            user_input = input("\nYou: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nGoodbye!")
            break
        
        if not user_input:
            continue
        
        if user_input.lower() in ("quit", "exit"):
            print("Goodbye!")
            break
        
        if user_input.lower() == "clear":
            messages = []
            if system_prompt:
                messages.append({"role": "system", "content": system_prompt})
            print("Conversation cleared.")
            continue
        
        messages.append({"role": "user", "content": user_input})
        
        try:
            print("\nAssistant: ", end="", flush=True)
            response = client.chat(messages, stream=True)
            messages.append({"role": "assistant", "content": response})
        except Exception as e:
            print(f"\nError: {e}")
            messages.pop()  # Remove failed user message


def main():
    parser = argparse.ArgumentParser(description="Universal vLLM Client")
    parser.add_argument("--endpoint", "-e", type=str, default=VLLM_ENDPOINT,
                        help="vLLM endpoint URL")
    parser.add_argument("--prompt", "-p", type=str,
                        help="Single prompt to send")
    parser.add_argument("--system", "-sys", type=str,
                        default="You are a helpful AI assistant.",
                        help="System prompt")
    parser.add_argument("--chat", "-c", action="store_true",
                        help="Run interactive chat mode")
    parser.add_argument("--image", "-i", type=str,
                        help="Image path/URL for vision models")
    parser.add_argument("--stream", "-s", action="store_true",
                        help="Stream the response")
    parser.add_argument("--max-tokens", "-m", type=int, default=1024,
                        help="Maximum tokens to generate")
    parser.add_argument("--benchmark", "-b", action="store_true",
                        help="Run performance benchmark")
    parser.add_argument("--health", action="store_true",
                        help="Only check health status")
    
    args = parser.parse_args()
    
    client = VLLMClient(args.endpoint)
    
    print(f"🔌 vLLM Universal Client")
    print(f"   Endpoint: {args.endpoint}")
    
    # Health check
    if not client.health_check():
        print(f"\n✗ Cannot connect to vLLM at {args.endpoint}")
        sys.exit(1)
    print(f"   Status: ✓ Connected")
    
    # Detect model
    model = client.detect_model()
    if not model:
        print("✗ No model loaded")
        sys.exit(1)
    print(f"   Model: {model}")
    
    if client.is_vision_model():
        print(f"   Type: Vision-Language Model")
    
    if args.health:
        print("\n✓ Health check passed")
        return
    
    print()
    
    # Handle different modes
    if args.benchmark:
        results = client.benchmark()
        if results:
            print(f"\n📊 Benchmark Results:")
            print(f"   Avg Latency: {results['avg_latency']:.2f}s")
            print(f"   Avg Tokens: {results['avg_tokens']:.0f}")
            print(f"   Tokens/sec: {results['tokens_per_second']:.1f}")
        return
    
    if args.chat:
        interactive_chat(client, args.system)
        return
    
    if args.image:
        if not client.is_vision_model():
            print(f"⚠️  Warning: {model} may not support vision. Trying anyway...")
        
        prompt = args.prompt or "Describe this image in detail."
        print(f"Image: {args.image}")
        print(f"Prompt: {prompt}")
        print("\nAnalyzing...")
        
        try:
            response = client.vision_chat(args.image, prompt, max_tokens=args.max_tokens)
            print(f"\nAssistant: {response}")
        except Exception as e:
            print(f"Error: {e}")
        return
    
    # Single prompt mode
    prompt = args.prompt or "Hello! What can you help me with today?"
    messages = [
        {"role": "system", "content": args.system},
        {"role": "user", "content": prompt}
    ]
    
    print(f"User: {prompt}\n")
    
    try:
        if args.stream:
            print("Assistant: ", end="", flush=True)
            client.chat(messages, stream=True, max_tokens=args.max_tokens)
        else:
            response = client.chat(messages, stream=False, max_tokens=args.max_tokens)
            print(f"Assistant: {response}")
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
