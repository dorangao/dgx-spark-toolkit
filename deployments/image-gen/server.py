#!/usr/bin/env python3
"""
Universal Image Generation Server
Supports multiple diffusion models with a Gradio web interface and REST API.

Usage:
    python server.py --model qwen-image-2512      # Qwen's model (41GB)
    python server.py --model stable-diffusion-xl  # SDXL (12GB)
    python server.py --model flux2-dev            # FLUX.2 Dev (gated)
    python server.py --model sd35-medium          # SD 3.5 Medium (gated)
"""

import argparse
import os
import json
import base64
from io import BytesIO
from pathlib import Path
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Model configurations
MODEL_CONFIGS = {
    "qwen-image-2512": {
        "repo_id": "Qwen/Qwen-Image-2512",
        "pipeline_class": "DiffusionPipeline",
        "default_steps": 30,
        "default_guidance": 7.5,
        "default_size": (2512, 2512),
        "dtype": "bfloat16",
    },
    "stable-diffusion-xl": {
        "repo_id": "stabilityai/stable-diffusion-xl-base-1.0",
        "pipeline_class": "StableDiffusionXLPipeline",
        "default_steps": 30,
        "default_guidance": 7.5,
        "default_size": (1024, 1024),
        "dtype": "float16",
    },
    "flux2-dev": {
        "repo_id": "black-forest-labs/FLUX.2-dev",
        "pipeline_class": "Flux2Pipeline",
        "default_steps": 28,
        "default_guidance": 4.0,
        "default_size": (1024, 1024),
        "dtype": "bfloat16",
        "gated": True,  # Requires HF auth & license
    },
    "sd35-medium": {
        "repo_id": "stabilityai/stable-diffusion-3.5-medium",
        "pipeline_class": "StableDiffusion3Pipeline",
        "default_steps": 28,
        "default_guidance": 4.5,
        "default_size": (1024, 1024),
        "dtype": "float16",
        "gated": True,  # Requires HF auth & license
    },
}


def load_pipeline(model_name: str):
    """Load the specified diffusion pipeline."""
    import torch
    from diffusers import DiffusionPipeline, StableDiffusionXLPipeline, StableDiffusion3Pipeline
    try:
        from diffusers import Flux2Pipeline
    except ImportError:
        from diffusers import FluxPipeline as Flux2Pipeline  # Fallback for older diffusers
    
    if model_name not in MODEL_CONFIGS:
        raise ValueError(f"Unknown model: {model_name}. Available: {list(MODEL_CONFIGS.keys())}")
    
    config = MODEL_CONFIGS[model_name]
    logger.info(f"Loading {model_name} from {config['repo_id']}...")
    
    # Get dtype
    dtype_map = {
        "float16": torch.float16,
        "bfloat16": torch.bfloat16,
        "float32": torch.float32,
    }
    dtype = dtype_map.get(config["dtype"], torch.bfloat16)
    
    # Get cache directory
    cache_dir = os.environ.get("HF_HOME", os.path.expanduser("~/.cache/huggingface"))
    
    # Load appropriate pipeline
    pipeline_classes = {
        "DiffusionPipeline": DiffusionPipeline,
        "StableDiffusionXLPipeline": StableDiffusionXLPipeline,
        "Flux2Pipeline": Flux2Pipeline,
        "StableDiffusion3Pipeline": StableDiffusion3Pipeline,
    }
    
    PipelineClass = pipeline_classes.get(config["pipeline_class"], DiffusionPipeline)
    
    pipe = PipelineClass.from_pretrained(
        config["repo_id"],
        torch_dtype=dtype,
        cache_dir=cache_dir,
        trust_remote_code=True,
    )
    
    # Move to GPU
    if torch.cuda.is_available():
        pipe = pipe.to("cuda")
        device_name = torch.cuda.get_device_name()
        logger.info(f"Using GPU: {device_name}")
    else:
        logger.warning("No GPU available, using CPU (very slow)")
    
    return pipe, config


def generate_image(pipe, config, prompt: str, negative_prompt: str = "",
                   steps: int = None, guidance: float = None, 
                   width: int = None, height: int = None, seed: int = -1):
    """Generate an image from a text prompt."""
    import torch
    
    steps = steps or config["default_steps"]
    guidance = guidance if guidance is not None else config["default_guidance"]
    width = width or config["default_size"][0]
    height = height or config["default_size"][1]
    
    logger.info(f"Generating: '{prompt[:50]}...' steps={steps} guidance={guidance}")
    
    # Set seed if specified
    generator = None
    if seed >= 0:
        generator = torch.Generator(device="cuda" if torch.cuda.is_available() else "cpu")
        generator.manual_seed(seed)
    
    # Generate
    kwargs = {
        "prompt": prompt,
        "num_inference_steps": steps,
        "guidance_scale": guidance,
        "generator": generator,
    }
    
    # Add width/height - most modern diffusion models support these
    # Check pipeline's __call__ signature to see if width/height are accepted
    import inspect
    call_sig = inspect.signature(pipe.__call__)
    call_params = call_sig.parameters
    
    if "width" in call_params:
        kwargs["width"] = width
    if "height" in call_params:
        kwargs["height"] = height
    
    logger.info(f"Generation params: width={width}, height={height}, steps={steps}, guidance={guidance}")
    
    # Add negative prompt if supported and provided
    if negative_prompt and "negative_prompt" in call_params:
        kwargs["negative_prompt"] = negative_prompt
    
    result = pipe(**kwargs)
    return result.images[0]


def image_to_base64(image):
    """Convert PIL image to base64 string."""
    buffered = BytesIO()
    image.save(buffered, format="PNG")
    return base64.b64encode(buffered.getvalue()).decode()


def start_server(model_name: str, port: int = 7860):
    """Start Gradio web interface with REST API."""
    import gradio as gr
    from fastapi import FastAPI
    from fastapi.responses import JSONResponse
    import uvicorn
    
    pipe, config = load_pipeline(model_name)
    
    # Create Gradio interface
    def gradio_generate(prompt, negative_prompt, steps, guidance, width, height, seed):
        image = generate_image(
            pipe, config, prompt, negative_prompt,
            int(steps), float(guidance), int(width), int(height), int(seed)
        )
        return image
    
    with gr.Blocks(title=f"Image Generation - {model_name}") as demo:
        gr.Markdown(f"# 🎨 {model_name.replace('-', ' ').title()}")
        gr.Markdown(f"Model: `{config['repo_id']}`")
        
        with gr.Row():
            with gr.Column(scale=2):
                prompt = gr.Textbox(
                    label="Prompt",
                    placeholder="Describe the image you want to create...",
                    lines=3
                )
                negative_prompt = gr.Textbox(
                    label="Negative Prompt (optional)",
                    placeholder="What to avoid in the image...",
                    lines=2
                )
                
                with gr.Row():
                    steps = gr.Slider(1, 100, value=config["default_steps"], step=1, label="Steps")
                    guidance = gr.Slider(0, 20, value=config["default_guidance"], step=0.5, label="Guidance Scale")
                
                with gr.Row():
                    width = gr.Slider(256, 2560, value=config["default_size"][0], step=64, label="Width")
                    height = gr.Slider(256, 2560, value=config["default_size"][1], step=64, label="Height")
                
                seed = gr.Number(label="Seed (-1 for random)", value=-1)
                generate_btn = gr.Button("🎨 Generate", variant="primary")
            
            with gr.Column(scale=3):
                output_image = gr.Image(label="Generated Image", type="pil")
        
        generate_btn.click(
            fn=gradio_generate,
            inputs=[prompt, negative_prompt, steps, guidance, width, height, seed],
            outputs=output_image
        )
    
    # Add REST API endpoint
    app = FastAPI()
    
    @app.post("/api/generate")
    async def api_generate(request_data: dict):
        try:
            image = generate_image(
                pipe, config,
                prompt=request_data.get("prompt", ""),
                negative_prompt=request_data.get("negative_prompt", ""),
                steps=request_data.get("steps"),
                guidance=request_data.get("guidance_scale"),
                width=request_data.get("width"),
                height=request_data.get("height"),
                seed=request_data.get("seed", -1)
            )
            
            # Save to temp file and return path or base64
            if request_data.get("return_base64", True):
                return JSONResponse({
                    "success": True,
                    "image_base64": image_to_base64(image),
                    "format": "png"
                })
            else:
                output_path = f"/tmp/generated_{hash(request_data.get('prompt', ''))}.png"
                image.save(output_path)
                return JSONResponse({
                    "success": True,
                    "image_path": output_path
                })
        except Exception as e:
            logger.error(f"Generation failed: {e}")
            return JSONResponse({"success": False, "error": str(e)}, status_code=500)
    
    @app.get("/api/health")
    async def health():
        return {"status": "healthy", "model": model_name}
    
    @app.get("/api/model-info")
    async def model_info():
        return {
            "model": model_name,
            "config": config,
            "gpu_available": __import__("torch").cuda.is_available()
        }
    
    # Mount Gradio app
    app = gr.mount_gradio_app(app, demo, path="/")
    
    logger.info(f"\n🎨 Starting {model_name} server on http://0.0.0.0:{port}")
    logger.info(f"   Web UI: http://0.0.0.0:{port}/")
    logger.info(f"   API: http://0.0.0.0:{port}/api/generate")
    logger.info(f"   Health: http://0.0.0.0:{port}/api/health")
    
    uvicorn.run(app, host="0.0.0.0", port=port)


def main():
    parser = argparse.ArgumentParser(description="Universal Image Generation Server")
    parser.add_argument("--model", "-m", default="qwen-image-2512",
                        choices=list(MODEL_CONFIGS.keys()),
                        help="Model to load")
    parser.add_argument("--port", "-p", type=int, default=7860, help="Server port")
    parser.add_argument("--list-models", action="store_true", help="List available models")
    
    args = parser.parse_args()
    
    if args.list_models:
        print("Available models:")
        for name, config in MODEL_CONFIGS.items():
            print(f"  {name}: {config['repo_id']}")
        return
    
    start_server(args.model, args.port)


if __name__ == "__main__":
    main()
