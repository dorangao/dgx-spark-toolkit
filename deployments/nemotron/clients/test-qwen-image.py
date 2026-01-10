#!/usr/bin/env python3
"""
Test client for Qwen-Image-2512 vision model.
A vision-language model for image understanding, captioning, and visual QA.

Usage:
    python test-qwen-image.py --image path/to/image.jpg
    python test-qwen-image.py --image https://example.com/image.png --prompt "What's in this image?"
    python test-qwen-image.py --url https://example.com/image.jpg
"""

import argparse
import base64
import json
import os
import sys
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# Default endpoint
VLLM_ENDPOINT = os.environ.get("VLLM_ENDPOINT", "http://192.168.86.203:8081")
MODEL_NAME = "Qwen/Qwen-Image-2512"

# Sample test image URL
SAMPLE_IMAGE_URL = "https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/PNG_transparency_demonstration_1.png/280px-PNG_transparency_demonstration_1.png"


def encode_image_to_base64(image_path: str) -> str:
    """Encode a local image file to base64."""
    with open(image_path, "rb") as f:
        return base64.b64encode(f.read()).decode()


def get_image_mime_type(path: str) -> str:
    """Get MIME type from file extension."""
    ext = Path(path).suffix.lower()
    mime_types = {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".gif": "image/gif",
        ".webp": "image/webp",
    }
    return mime_types.get(ext, "image/jpeg")


def vision_completion(image_source: str, prompt: str, max_tokens: int = 512, endpoint: str = None):
    """Send a vision completion request to vLLM."""
    base_url = endpoint or VLLM_ENDPOINT
    url = f"{base_url}/v1/chat/completions"
    
    # Determine if image is URL or local file
    if image_source.startswith(("http://", "https://")):
        image_content = {
            "type": "image_url",
            "image_url": {"url": image_source}
        }
    else:
        # Local file - encode to base64
        if not os.path.exists(image_source):
            print(f"Error: Image file not found: {image_source}")
            sys.exit(1)
        
        mime_type = get_image_mime_type(image_source)
        base64_data = encode_image_to_base64(image_source)
        image_content = {
            "type": "image_url",
            "image_url": {"url": f"data:{mime_type};base64,{base64_data}"}
        }
    
    payload = {
        "model": MODEL_NAME,
        "messages": [
            {
                "role": "user",
                "content": [
                    image_content,
                    {"type": "text", "text": prompt}
                ]
            }
        ],
        "max_tokens": max_tokens,
        "temperature": 0.7,
    }
    
    headers = {
        "Content-Type": "application/json",
    }
    
    req = Request(url, data=json.dumps(payload).encode(), headers=headers, method="POST")
    
    try:
        print("Analyzing image...")
        with urlopen(req, timeout=180) as response:
            result = json.loads(response.read().decode())
            content = result["choices"][0]["message"]["content"]
            print(f"\nAssistant: {content}")
            
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


def check_health(endpoint: str = None):
    """Check if the model is loaded and healthy."""
    base_url = endpoint or VLLM_ENDPOINT
    try:
        req = Request(f"{base_url}/health")
        with urlopen(req, timeout=5) as response:
            print(f"✓ vLLM is healthy")
            
        # Check models
        req = Request(f"{base_url}/v1/models")
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
    parser = argparse.ArgumentParser(description="Test Qwen-Image-2512 vision model")
    parser.add_argument("--image", "-i", type=str,
                        help="Path to local image file or URL")
    parser.add_argument("--url", "-u", type=str,
                        help="URL of image to analyze (alias for --image)")
    parser.add_argument("--prompt", "-p", type=str, 
                        default="Describe this image in detail. What do you see?",
                        help="Prompt/question about the image")
    parser.add_argument("--max-tokens", "-m", type=int, default=512,
                        help="Maximum tokens to generate")
    parser.add_argument("--endpoint", "-e", type=str, default=VLLM_ENDPOINT,
                        help="vLLM endpoint URL")
    parser.add_argument("--health", action="store_true",
                        help="Only check health status")
    parser.add_argument("--demo", action="store_true",
                        help="Run demo with sample image")
    
    args = parser.parse_args()
    
    endpoint = args.endpoint
    
    print(f"🖼️  Qwen-Image-2512 Vision Test Client")
    print(f"   Endpoint: {endpoint}")
    print(f"   Model: {MODEL_NAME}")
    print()
    
    if args.health:
        check_health(endpoint)
        return
    
    if not check_health(endpoint):
        return
    
    # Determine image source
    image_source = args.image or args.url
    
    if args.demo or not image_source:
        print(f"\n📸 Using sample image: {SAMPLE_IMAGE_URL}")
        image_source = SAMPLE_IMAGE_URL
    
    print()
    print(f"Image: {image_source[:80]}{'...' if len(image_source) > 80 else ''}")
    print(f"Prompt: {args.prompt}")
    print()
    
    vision_completion(image_source, args.prompt, max_tokens=args.max_tokens, endpoint=endpoint)


if __name__ == "__main__":
    main()
