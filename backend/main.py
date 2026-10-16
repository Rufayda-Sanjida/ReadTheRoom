"""FastAPI entry point. Run with:  uvicorn main:app --reload   (then open /docs)

The app follows MVC (see README.md):
  models/       Model: data and SQL (SQLite)
  views/        View: the JSON shapes the API accepts and returns
  controllers/  Controller: HTTP routes that tie models, services and views together
  services/     business logic the controllers call (analytics, AI agent)
"""

import config  # noqa: F401  (must be first: loads .env before anything reads API keys)

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from controllers import chat_controller, insight_controller, reaction_controller, session_controller
from models.database import init_db
from services import storage


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    yield


app = FastAPI(title="Reaction Analytics API", lifespan=lifespan)

# Wide open for the hackathon so the React dev server can call us.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

if storage.BUCKET:
    # On AWS, uploads live in S3: serve them through a redirect to a temporary S3 link.
    @app.get("/videos/{name}", include_in_schema=False)
    @app.get("/api/videos/{name}", include_in_schema=False)
    def video(name: str):
        return storage.serve(name)
else:
    # Mount static file route to serve uploaded videos
    app.mount("/videos", StaticFiles(directory=str(config.VIDEOS_DIR)), name="videos")
    app.mount("/api/videos", StaticFiles(directory=str(config.VIDEOS_DIR)), name="api_videos")

for controller in (session_controller, reaction_controller, insight_controller, chat_controller):
    app.include_router(controller.router)


@app.get("/health", tags=["health"])
def health():
    return {"ok": True}
