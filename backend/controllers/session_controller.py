import os
import re
import uuid
from pathlib import Path

from fastapi import APIRouter, File, HTTPException, UploadFile

from models import reaction, session
from models.database import IntegrityError
from services import storage
from views.schemas import Session, SessionCreate

router = APIRouter(prefix="/sessions", tags=["sessions"])


@router.post("/upload-video")
async def upload_video(file: UploadFile = File(...)):
    """Upload a video file for a session, saving it (disk locally, S3 on AWS) and returning its public URL."""
    if not file.filename:
        raise HTTPException(400, "Filename cannot be empty")

    ext = Path(file.filename).suffix.lower()
    allowed_exts = {".mp4", ".webm", ".mov", ".m4v", ".ogv", ".ogg"}
    if ext not in allowed_exts:
        raise HTTPException(400, f"Unsupported video format '{ext}'. Allowed: {', '.join(allowed_exts)}")

    safe_base = re.sub(r"[^a-zA-Z0-9_\-\.]", "_", Path(file.filename).stem)
    unique_name = f"{uuid.uuid4().hex[:10]}_{safe_base}{ext}"

    try:
        file_size = file.file.seek(0, os.SEEK_END)
        file.file.seek(0)
        storage.save(unique_name, file.file)
    except Exception as e:
        raise HTTPException(500, f"Failed to save video file: {e}")
    finally:
        await file.close()

    video_url = f"/api/videos/{unique_name}"
    return {
        "filename": unique_name,
        "original_name": file.filename,
        "video_url": video_url,
        "size": file_size,
    }



def require_session(session_id: str) -> dict:
    """Shared by all controllers: the session, or a 404 if it doesn't exist."""
    found = session.get(session_id)
    if not found:
        raise HTTPException(404, f"Session '{session_id}' not found")
    return found


@router.post("", response_model=Session, status_code=201)
def create_session(body: SessionCreate):
    try:
        session_id = session.create(body.id, body.name, body.video_url)
    except IntegrityError:
        raise HTTPException(409, f"Session '{body.id}' already exists")
    if body.reactions:
        reaction.add_many(session_id, [r.model_dump() for r in body.reactions])
    return require_session(session_id)


@router.get("", response_model=list[Session])
def list_sessions():
    return session.list_all()


@router.get("/{session_id}", response_model=Session)
def get_session(session_id: str):
    return require_session(session_id)


@router.delete("/{session_id}", status_code=204)
def delete_session(session_id: str):
    require_session(session_id)
    session.delete(session_id)
    return None
