# vLLM Model Test Clients

Test clients for the various LLM models supported by the DGX Spark deployment.

## Quick Start

```bash
# Check health of vLLM service
python vllm-client.py --health

# Run interactive chat with auto-detected model
python vllm-client.py --chat

# Single prompt
python vllm-client.py --prompt "Explain machine learning"

# With streaming
python vllm-client.py --prompt "Write a poem about space" --stream
```

## Available Clients

| Script | Model | Use Case |
|--------|-------|----------|
| `vllm-client.py` | Any (auto-detect) | Universal client, interactive chat |
| `test-nemotron-nano.py` | Nemotron-3 Nano 30B | Reasoning, instruction following |
| `test-qwen-image.py` | Qwen-Image-2512 | Vision, image understanding |
| `test-qwen-32b.py` | Qwen2.5-32B | Complex reasoning, long-form |
| `test-llama-70b.py` | Llama-3.1-70B | General purpose, large model |
| `test-deepseek-coder.py` | DeepSeek-Coder-V2 | Code generation, programming |
| `test-mistral-nemo.py` | Mistral-Nemo-12B | Efficient, fast responses |

## Configuration

Set the vLLM endpoint via environment variable:

```bash
export VLLM_ENDPOINT="http://192.168.86.203:8081"
```

Or use the `--endpoint` flag:

```bash
python vllm-client.py --endpoint http://localhost:8081 --prompt "Hello"
```

## Model-Specific Examples

### Nemotron-3 Nano 30B (Reasoning)

```bash
# Basic test
python test-nemotron-nano.py

# Custom prompt with streaming
python test-nemotron-nano.py --prompt "Solve this step by step: If a train travels 120 km in 2 hours, what is its speed in m/s?" --stream
```

### Qwen-Image-2512 (Vision)

```bash
# Analyze a local image
python test-qwen-image.py --image /path/to/photo.jpg

# Analyze image from URL
python test-qwen-image.py --url https://example.com/image.png --prompt "What objects are in this image?"

# Run demo with sample image
python test-qwen-image.py --demo
```

### DeepSeek-Coder-V2 (Code)

```bash
# Generate code
python test-deepseek-coder.py --prompt "Write a Python decorator for caching"

# Complete code
python test-deepseek-coder.py --code "def quicksort(arr):" --task complete

# Fix buggy code
python test-deepseek-coder.py --code "for i in range(10)\n  print(i" --task fix

# Explain code
python test-deepseek-coder.py --code "lambda x: x**2 if x > 0 else -x" --task explain
```

### Universal Client Features

```bash
# Interactive multi-turn chat
python vllm-client.py --chat

# Run benchmark (5 requests)
python vllm-client.py --benchmark

# Vision with any model (auto-detects if supported)
python vllm-client.py --image photo.jpg --prompt "Describe this"

# Custom system prompt
python vllm-client.py --system "You are a pirate" --prompt "Tell me about ships"
```

## Common Options

| Option | Description |
|--------|-------------|
| `--endpoint`, `-e` | vLLM API endpoint URL |
| `--prompt`, `-p` | Prompt/question to send |
| `--stream`, `-s` | Stream response tokens |
| `--max-tokens`, `-m` | Max tokens to generate |
| `--health` | Check service health only |
| `--system`, `-sys` | Set system prompt |

## Troubleshooting

### Connection Refused
```
Is vLLM running at http://192.168.86.203:8081?
```
Check that the model is deployed:
```bash
./deploy-distributed.sh --status
```

### Model Not Found
The health check shows models but API fails:
- Model may still be loading (first startup takes 10-15 min)
- Check Ray dashboard at http://192.168.86.203:8265

### Timeout Errors
Large models take longer:
```bash
# Increase timeout in client or use streaming
python vllm-client.py --stream --max-tokens 2048
```

## API Compatibility

These clients use the OpenAI-compatible API provided by vLLM:
- `/v1/chat/completions` - Chat completions
- `/v1/models` - List models
- `/health` - Health check

Compatible with any OpenAI SDK:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://192.168.86.203:8081/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16",
    messages=[{"role": "user", "content": "Hello!"}]
)
print(response.choices[0].message.content)
```
