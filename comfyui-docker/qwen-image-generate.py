#!/usr/bin/env python3
"""
Qwen-Image-2512 Text-to-Image Generation

Usage:
    python qwen-image-generate.py "a beautiful sunset over mountains"
    python qwen-image-generate.py "a cat wearing a hat" --output cat.png
    python qwen-image-generate.py --server  # Start API server

Requirements:
    pip install diffusers transformers accelerate torch gradio
"""

import argparse
import os
from pathlib import Path

def load_pipeline():
    """Load the Qwen-Image-2512 pipeline."""
    from diffusers import DiffusionPipeline
    import torch
    
    print("Loading Qwen-Image-2512 model (this may take a few minutes on first run)...")
    
    # Use cache directory
    cache_dir = os.environ.get("HF_HOME", os.path.expanduser("~/.cache/huggingface"))
    
    pipe = DiffusionPipeline.from_pretrained(
        "Qwen/Qwen-Image-2512",
        torch_dtype=torch.bfloat16,
        cache_dir=cache_dir,
        trust_remote_code=True,
    )
    
    # Move to GPU
    if torch.cuda.is_available():
        pipe = pipe.to("cuda")
        print(f"Using GPU: {torch.cuda.get_device_name()}")
    else:
        print("Warning: No GPU available, using CPU (very slow)")
    
    return pipe


def generate_image(pipe, prompt: str, output_path: str = None, 
                   num_steps: int = 30, guidance_scale: float = 7.5):
    """Generate an image from a text prompt."""
    print(f"Generating image for: '{prompt}'")
    
    image = pipe(
        prompt=prompt,
        num_inference_steps=num_steps,
        guidance_scale=guidance_scale,
    ).images[0]
    
    if output_path is None:
        # Generate filename from prompt
        safe_name = "".join(c if c.isalnum() else "_" for c in prompt[:30])
        output_path = f"output_{safe_name}.png"
    
    image.save(output_path)
    print(f"Saved to: {output_path}")
    return output_path


def start_server(port: int = 7860):
    """Start a Gradio web interface."""
    try:
        import gradio as gr
    except ImportError:
        print("Installing gradio...")
        os.system("pip install gradio")
        import gradio as gr
    
    pipe = load_pipeline()
    
    def generate(prompt, steps, guidance):
        output = f"/tmp/qwen_output_{hash(prompt)}.png"
        generate_image(pipe, prompt, output, int(steps), float(guidance))
        return output
    
    interface = gr.Interface(
        fn=generate,
        inputs=[
            gr.Textbox(label="Prompt", placeholder="Describe the image you want..."),
            gr.Slider(10, 50, value=30, step=1, label="Steps"),
            gr.Slider(1.0, 15.0, value=7.5, step=0.5, label="Guidance Scale"),
        ],
        outputs=gr.Image(label="Generated Image"),
        title="🎨 Qwen-Image-2512",
        description="Generate images using Qwen-Image-2512",
    )
    
    print(f"\n🎨 Starting Qwen-Image server on http://0.0.0.0:{port}")
    interface.launch(server_name="0.0.0.0", server_port=port, share=False)


def main():
    parser = argparse.ArgumentParser(description="Qwen-Image-2512 Text-to-Image Generator")
    parser.add_argument("prompt", nargs="?", help="Text prompt for image generation")
    parser.add_argument("--output", "-o", help="Output file path")
    parser.add_argument("--steps", type=int, default=30, help="Number of diffusion steps")
    parser.add_argument("--guidance", type=float, default=7.5, help="Guidance scale")
    parser.add_argument("--server", action="store_true", help="Start web UI server")
    parser.add_argument("--port", type=int, default=7860, help="Server port")
    
    args = parser.parse_args()
    
    if args.server:
        start_server(args.port)
    elif args.prompt:
        pipe = load_pipeline()
        generate_image(pipe, args.prompt, args.output, args.steps, args.guidance)
    else:
        parser.print_help()
        print("\nExamples:")
        print('  python qwen-image-generate.py "a magical forest at night"')
        print('  python qwen-image-generate.py --server')


if __name__ == "__main__":
    main()
