#!/usr/bin/env python3
"""
Universal Image Generation Server
Supports multiple diffusion models with a Gradio web interface and REST API.
Includes persistent storage, generation history, and performance tracking.

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
import sqlite3
import time
import uuid
from io import BytesIO
from pathlib import Path
from datetime import datetime
import logging
import threading

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Storage configuration
STORAGE_DIR = Path(os.environ.get("IMAGE_STORAGE_DIR", "/models/generated_images"))
DB_PATH = STORAGE_DIR / "history.db"

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
        "gated": True,
    },
    "sd35-medium": {
        "repo_id": "stabilityai/stable-diffusion-3.5-medium",
        "pipeline_class": "StableDiffusion3Pipeline",
        "default_steps": 28,
        "default_guidance": 4.5,
        "default_size": (1024, 1024),
        "dtype": "bfloat16",
        "gated": True,
    },
}


# Database setup
def init_database():
    """Initialize SQLite database for generation history."""
    STORAGE_DIR.mkdir(parents=True, exist_ok=True)
    
    conn = sqlite3.connect(str(DB_PATH))
    cursor = conn.cursor()
    
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS generations (
            id TEXT PRIMARY KEY,
            timestamp TEXT NOT NULL,
            model TEXT NOT NULL,
            prompt TEXT NOT NULL,
            negative_prompt TEXT,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            steps INTEGER NOT NULL,
            guidance_scale REAL NOT NULL,
            seed INTEGER,
            generation_time_ms INTEGER NOT NULL,
            image_path TEXT NOT NULL,
            node_name TEXT,
            gpu_name TEXT
        )
    """)
    
    # Create index for faster queries
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_timestamp ON generations(timestamp DESC)")
    cursor.execute("CREATE INDEX IF NOT EXISTS idx_model ON generations(model)")
    
    conn.commit()
    conn.close()
    logger.info(f"Database initialized at {DB_PATH}")


def save_generation(gen_id: str, model: str, prompt: str, negative_prompt: str,
                   width: int, height: int, steps: int, guidance: float,
                   seed: int, gen_time_ms: int, image_path: str,
                   node_name: str = None, gpu_name: str = None):
    """Save generation metadata to database."""
    conn = sqlite3.connect(str(DB_PATH))
    cursor = conn.cursor()
    
    cursor.execute("""
        INSERT INTO generations 
        (id, timestamp, model, prompt, negative_prompt, width, height, steps, 
         guidance_scale, seed, generation_time_ms, image_path, node_name, gpu_name)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        gen_id,
        datetime.utcnow().isoformat(),
        model,
        prompt,
        negative_prompt,
        width,
        height,
        steps,
        guidance,
        seed,
        gen_time_ms,
        image_path,
        node_name or os.environ.get("NODE_NAME", "unknown"),
        gpu_name
    ))
    
    conn.commit()
    conn.close()


def get_generation_history(limit: int = 50, offset: int = 0, model: str = None):
    """Get generation history from database."""
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    
    if model:
        cursor.execute("""
            SELECT * FROM generations 
            WHERE model = ?
            ORDER BY timestamp DESC 
            LIMIT ? OFFSET ?
        """, (model, limit, offset))
    else:
        cursor.execute("""
            SELECT * FROM generations 
            ORDER BY timestamp DESC 
            LIMIT ? OFFSET ?
        """, (limit, offset))
    
    rows = cursor.fetchall()
    conn.close()
    
    return [dict(row) for row in rows]


def get_generation_stats():
    """Get generation statistics."""
    conn = sqlite3.connect(str(DB_PATH))
    cursor = conn.cursor()
    
    stats = {}
    
    # Total count
    cursor.execute("SELECT COUNT(*) FROM generations")
    stats["total_generations"] = cursor.fetchone()[0]
    
    # Per model stats
    cursor.execute("""
        SELECT model, 
               COUNT(*) as count,
               AVG(generation_time_ms) as avg_time_ms,
               MIN(generation_time_ms) as min_time_ms,
               MAX(generation_time_ms) as max_time_ms
        FROM generations 
        GROUP BY model
    """)
    stats["by_model"] = {}
    for row in cursor.fetchall():
        stats["by_model"][row[0]] = {
            "count": row[1],
            "avg_time_ms": round(row[2], 2) if row[2] else 0,
            "min_time_ms": row[3],
            "max_time_ms": row[4]
        }
    
    # Per resolution stats
    cursor.execute("""
        SELECT width || 'x' || height as resolution,
               COUNT(*) as count,
               AVG(generation_time_ms) as avg_time_ms
        FROM generations 
        GROUP BY resolution
        ORDER BY count DESC
        LIMIT 10
    """)
    stats["by_resolution"] = {}
    for row in cursor.fetchall():
        stats["by_resolution"][row[0]] = {
            "count": row[1],
            "avg_time_ms": round(row[2], 2) if row[2] else 0
        }
    
    conn.close()
    return stats


def load_pipeline(model_name: str):
    """Load the specified diffusion pipeline."""
    import torch
    from diffusers import DiffusionPipeline, StableDiffusionXLPipeline, StableDiffusion3Pipeline
    try:
        from diffusers import Flux2Pipeline
    except ImportError:
        from diffusers import FluxPipeline as Flux2Pipeline
    
    if model_name not in MODEL_CONFIGS:
        raise ValueError(f"Unknown model: {model_name}. Available: {list(MODEL_CONFIGS.keys())}")
    
    config = MODEL_CONFIGS[model_name]
    logger.info(f"Loading {model_name} from {config['repo_id']}...")
    
    dtype_map = {
        "float16": torch.float16,
        "bfloat16": torch.bfloat16,
        "float32": torch.float32,
    }
    dtype = dtype_map.get(config["dtype"], torch.bfloat16)
    
    cache_dir = os.environ.get("HF_HOME", os.path.expanduser("~/.cache/huggingface"))
    
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
    
    gpu_name = None
    if torch.cuda.is_available():
        pipe = pipe.to("cuda")
        gpu_name = torch.cuda.get_device_name()
        logger.info(f"Using GPU: {gpu_name}")
    else:
        logger.warning("No GPU available, using CPU (very slow)")
    
    return pipe, config, gpu_name


def generate_image(pipe, config, model_name: str, prompt: str, negative_prompt: str = "",
                   steps: int = None, guidance: float = None, 
                   width: int = None, height: int = None, seed: int = -1,
                   gpu_name: str = None, save_to_disk: bool = True):
    """Generate an image from a text prompt with timing and persistence."""
    import torch
    
    steps = steps or config["default_steps"]
    guidance = guidance if guidance is not None else config["default_guidance"]
    width = width or config["default_size"][0]
    height = height or config["default_size"][1]
    
    logger.info(f"Generating: '{prompt[:50]}...' steps={steps} guidance={guidance}")
    
    # Set seed
    actual_seed = seed if seed >= 0 else torch.randint(0, 2**32, (1,)).item()
    generator = torch.Generator(device="cuda" if torch.cuda.is_available() else "cpu")
    generator.manual_seed(actual_seed)
    
    # Prepare kwargs
    kwargs = {
        "prompt": prompt,
        "num_inference_steps": steps,
        "guidance_scale": guidance,
        "generator": generator,
    }
    
    import inspect
    call_sig = inspect.signature(pipe.__call__)
    call_params = call_sig.parameters
    
    if "width" in call_params:
        kwargs["width"] = width
    if "height" in call_params:
        kwargs["height"] = height
    if negative_prompt and "negative_prompt" in call_params:
        kwargs["negative_prompt"] = negative_prompt
    
    logger.info(f"Generation params: width={width}, height={height}, steps={steps}, guidance={guidance}, seed={actual_seed}")
    
    # Time the generation
    start_time = time.time()
    result = pipe(**kwargs)
    gen_time_ms = int((time.time() - start_time) * 1000)
    
    image = result.images[0]
    logger.info(f"Generation completed in {gen_time_ms}ms ({gen_time_ms/1000:.2f}s)")
    
    # Save to disk and database
    gen_id = str(uuid.uuid4())
    image_path = None
    
    if save_to_disk:
        # Create date-based subdirectory
        date_dir = STORAGE_DIR / datetime.utcnow().strftime("%Y-%m-%d")
        date_dir.mkdir(parents=True, exist_ok=True)
        
        image_filename = f"{gen_id}.png"
        image_path = str(date_dir / image_filename)
        image.save(image_path)
        logger.info(f"Image saved to {image_path}")
        
        # Save to database
        save_generation(
            gen_id=gen_id,
            model=model_name,
            prompt=prompt,
            negative_prompt=negative_prompt,
            width=width,
            height=height,
            steps=steps,
            guidance=guidance,
            seed=actual_seed,
            gen_time_ms=gen_time_ms,
            image_path=image_path,
            gpu_name=gpu_name
        )
    
    return image, {
        "id": gen_id,
        "seed": actual_seed,
        "generation_time_ms": gen_time_ms,
        "image_path": image_path
    }


def image_to_base64(image):
    """Convert PIL image to base64 string."""
    buffered = BytesIO()
    image.save(buffered, format="PNG")
    return base64.b64encode(buffered.getvalue()).decode()


def start_server(model_name: str, port: int = 7860):
    """Start Gradio web interface with REST API."""
    import gradio as gr
    from fastapi import FastAPI
    from fastapi.responses import JSONResponse, FileResponse
    from fastapi.staticfiles import StaticFiles
    import uvicorn
    
    # Initialize database
    init_database()
    
    pipe, config, gpu_name = load_pipeline(model_name)
    
    # Create Gradio interface
    def gradio_generate(prompt, negative_prompt, steps, guidance, width, height, seed):
        image, meta = generate_image(
            pipe, config, model_name, prompt, negative_prompt,
            int(steps), float(guidance), int(width), int(height), int(seed),
            gpu_name=gpu_name
        )
        info = f"Generated in {meta['generation_time_ms']}ms | Seed: {meta['seed']} | ID: {meta['id'][:8]}"
        return image, info
    
    with gr.Blocks(title=f"Image Generation - {model_name}") as demo:
        gr.Markdown(f"# 🎨 {model_name.replace('-', ' ').title()}")
        gr.Markdown(f"Model: `{config['repo_id']}`")
        
        with gr.Tabs():
            with gr.Tab("Generate"):
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
                        gen_info = gr.Textbox(label="Generation Info", interactive=False)
                
                generate_btn.click(
                    fn=gradio_generate,
                    inputs=[prompt, negative_prompt, steps, guidance, width, height, seed],
                    outputs=[output_image, gen_info]
                )
            
            with gr.Tab("History"):
                gr.Markdown("### Recent Generations")
                gr.Markdown("View history via API: `/api/history`")
                
                def load_history():
                    history = get_generation_history(limit=20)
                    if not history:
                        return "No generations yet."
                    
                    lines = []
                    for h in history:
                        lines.append(f"**{h['timestamp'][:19]}** | {h['model']} | {h['width']}x{h['height']} | {h['generation_time_ms']}ms")
                        lines.append(f"> {h['prompt'][:100]}...")
                        lines.append("")
                    return "\n".join(lines)
                
                history_display = gr.Markdown(load_history)
                refresh_btn = gr.Button("🔄 Refresh")
                refresh_btn.click(fn=load_history, outputs=history_display)
            
            with gr.Tab("Stats"):
                gr.Markdown("### Generation Statistics")
                
                def load_stats():
                    stats = get_generation_stats()
                    lines = [f"**Total Generations:** {stats['total_generations']}", ""]
                    
                    if stats["by_model"]:
                        lines.append("**By Model:**")
                        for model, data in stats["by_model"].items():
                            lines.append(f"- {model}: {data['count']} images, avg {data['avg_time_ms']}ms")
                        lines.append("")
                    
                    if stats["by_resolution"]:
                        lines.append("**By Resolution:**")
                        for res, data in stats["by_resolution"].items():
                            lines.append(f"- {res}: {data['count']} images, avg {data['avg_time_ms']}ms")
                    
                    return "\n".join(lines)
                
                stats_display = gr.Markdown(load_stats)
                stats_refresh = gr.Button("🔄 Refresh Stats")
                stats_refresh.click(fn=load_stats, outputs=stats_display)
    
    # REST API
    app = FastAPI()
    
    @app.post("/api/generate")
    async def api_generate(request_data: dict):
        try:
            image, meta = generate_image(
                pipe, config, model_name,
                prompt=request_data.get("prompt", ""),
                negative_prompt=request_data.get("negative_prompt", ""),
                steps=request_data.get("steps"),
                guidance=request_data.get("guidance_scale"),
                width=request_data.get("width"),
                height=request_data.get("height"),
                seed=request_data.get("seed", -1),
                gpu_name=gpu_name
            )
            
            response = {
                "success": True,
                "id": meta["id"],
                "seed": meta["seed"],
                "generation_time_ms": meta["generation_time_ms"],
                "image_path": meta["image_path"],
                "format": "png"
            }
            
            if request_data.get("return_base64", True):
                response["image_base64"] = image_to_base64(image)
            
            return JSONResponse(response)
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
            "gpu_available": __import__("torch").cuda.is_available(),
            "gpu_name": gpu_name
        }
    
    @app.get("/api/history")
    async def api_history(limit: int = 50, offset: int = 0, model: str = None):
        """Get generation history."""
        history = get_generation_history(limit=limit, offset=offset, model=model)
        return {"success": True, "count": len(history), "history": history}
    
    @app.get("/api/stats")
    async def api_stats():
        """Get generation statistics."""
        stats = get_generation_stats()
        return {"success": True, "stats": stats}
    
    @app.get("/api/image/{gen_id}")
    async def get_image(gen_id: str):
        """Get a generated image by ID."""
        conn = sqlite3.connect(str(DB_PATH))
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM generations WHERE id = ?", (gen_id,))
        row = cursor.fetchone()
        conn.close()
        
        if not row:
            return JSONResponse({"success": False, "error": "Image not found"}, status_code=404)
        
        image_path = row["image_path"]
        if not Path(image_path).exists():
            return JSONResponse({"success": False, "error": "Image file not found"}, status_code=404)
        
        return FileResponse(image_path, media_type="image/png")
    
    @app.get("/api/image/{gen_id}/metadata")
    async def get_image_metadata(gen_id: str):
        """Get metadata for a generated image."""
        conn = sqlite3.connect(str(DB_PATH))
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        cursor.execute("SELECT * FROM generations WHERE id = ?", (gen_id,))
        row = cursor.fetchone()
        conn.close()
        
        if not row:
            return JSONResponse({"success": False, "error": "Image not found"}, status_code=404)
        
        return {"success": True, "metadata": dict(row)}
    
    # Serve generated images
    if STORAGE_DIR.exists():
        app.mount("/images", StaticFiles(directory=str(STORAGE_DIR)), name="images")
    
    # Mount Gradio app
    app = gr.mount_gradio_app(app, demo, path="/")
    
    logger.info(f"\n🎨 Starting {model_name} server on http://0.0.0.0:{port}")
    logger.info(f"   Web UI: http://0.0.0.0:{port}/")
    logger.info(f"   API: http://0.0.0.0:{port}/api/generate")
    logger.info(f"   History: http://0.0.0.0:{port}/api/history")
    logger.info(f"   Stats: http://0.0.0.0:{port}/api/stats")
    logger.info(f"   Health: http://0.0.0.0:{port}/api/health")
    logger.info(f"   Storage: {STORAGE_DIR}")
    
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
