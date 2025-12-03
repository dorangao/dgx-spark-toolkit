from __future__ import annotations

import os
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import List

import httpx
from fastapi import FastAPI, Form, HTTPException, Request, status
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

BASE_MODELS_DIR = Path(os.environ.get("COMFY_MODELS_DIR", "/workspace/ComfyUI/models")).resolve()
DEFAULT_FOLDERS = [
    "checkpoints",
    "text_encoders",
    "vae",
    "diffusion_models",
    "loras",
    "clip_vision",
    "style_models",
]

templates = Jinja2Templates(directory="templates")
app = FastAPI(title="ComfyUI Model Manager")


@dataclass
class ModelEntry:
    relative_path: str
    size_human: str
    modified: str


def _ensure_base_exists() -> None:
    BASE_MODELS_DIR.mkdir(parents=True, exist_ok=True)


def _human_size(num: int) -> str:
    step = 1024.0
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(num)
    for unit in units:
        if value < step:
            return f"{value:.1f} {unit}"
        value /= step
    return f"{value:.1f} PB"


def _safe_join(relative: str) -> Path:
    rel = relative.strip().lstrip("/")
    target = (BASE_MODELS_DIR / rel).resolve()
    if not str(target).startswith(str(BASE_MODELS_DIR)):
        raise HTTPException(status_code=400, detail="Path escapes model directory")
    return target


def list_models() -> List[ModelEntry]:
    _ensure_base_exists()
    entries: List[ModelEntry] = []
    for file_path in sorted(BASE_MODELS_DIR.rglob("*")):
        if file_path.is_file():
            rel = file_path.relative_to(BASE_MODELS_DIR).as_posix()
            stat = file_path.stat()
            entries.append(
                ModelEntry(
                    relative_path=rel,
                    size_human=_human_size(stat.st_size),
                    modified=datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M"),
                )
            )
    return entries


@app.get("/", response_class=HTMLResponse)
async def index(request: Request, msg: str | None = None, error: str | None = None):
    entries = list_models()
    derived_folders = {
        entry.relative_path.split("/")[0] for entry in entries if "/" in entry.relative_path
    }
    available_folders = sorted(set(DEFAULT_FOLDERS) | derived_folders)
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "entries": entries,
            "base_dir": str(BASE_MODELS_DIR),
            "folders": available_folders,
            "msg": msg,
            "error": error,
        },
    )


@app.post("/download")
async def download_model(
    url: str = Form(...),
    folder: str = Form("checkpoints"),
    filename: str = Form(""),
    overwrite: bool = Form(False),
):
    if not url.strip():
        raise HTTPException(status_code=400, detail="URL is required")

    name = filename.strip() or Path(url.split("?")[0]).name
    if not name:
        raise HTTPException(status_code=400, detail="Filename could not be inferred")

    rel_folder = folder.strip().lstrip("/")
    rel_path = (Path(rel_folder) / name) if rel_folder else Path(name)
    target_path = _safe_join(rel_path.as_posix())
    target_path.parent.mkdir(parents=True, exist_ok=True)

    if target_path.exists() and not overwrite:
        raise HTTPException(status_code=400, detail="File already exists (enable overwrite)")

    tmp_path = target_path.with_suffix(target_path.suffix + ".part")

    async with httpx.AsyncClient(follow_redirects=True, timeout=600) as client:
        try:
            async with client.stream("GET", url) as response:
                response.raise_for_status()
                with open(tmp_path, "wb") as f:
                    async for chunk in response.aiter_bytes():
                        f.write(chunk)
        except httpx.HTTPError as exc:
            if tmp_path.exists():
                tmp_path.unlink()
            raise HTTPException(status_code=400, detail=f"Download failed: {exc}")

    tmp_path.replace(target_path)

    return RedirectResponse(
        url=f"/?msg=Saved+{target_path.relative_to(BASE_MODELS_DIR).as_posix()}",
        status_code=status.HTTP_303_SEE_OTHER,
    )


@app.post("/delete")
async def delete_model(path: str = Form(...)):
    if not path:
        raise HTTPException(status_code=400, detail="Path required")
    target = _safe_join(path)
    if not target.exists():
        raise HTTPException(status_code=404, detail="File not found")
    if target.is_dir():
        raise HTTPException(status_code=400, detail="Deleting directories is not allowed")
    target.unlink()
    return RedirectResponse(
        url=f"/?msg=Deleted+{target.relative_to(BASE_MODELS_DIR).as_posix()}",
        status_code=status.HTTP_303_SEE_OTHER,
    )


@app.post("/refresh")
async def refresh_cache():
    # Endpoint to refresh listing for future expansion.
    return RedirectResponse(url="/", status_code=status.HTTP_303_SEE_OTHER)
