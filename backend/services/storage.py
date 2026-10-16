"""Where uploaded videos live: on local disk by default, in S3 when VIDEOS_BUCKET is set.

On AWS the containers are replaced on every deploy, so anything saved to their disk is lost;
S3 keeps the videos. Videos baked into the image (the demo) are still served from disk.
"""

import mimetypes
import os
import shutil
from typing import BinaryIO

from fastapi.responses import FileResponse, RedirectResponse, Response

import config

BUCKET = os.environ.get("VIDEOS_BUCKET", "")
PREFIX = "videos/"
URL_TTL_SECONDS = 3600

_s3 = None


def _client():
    global _s3
    if _s3 is None:
        import boto3
        from botocore.config import Config

        # SigV4: AWS no longer accepts the older signature style for presigned links.
        _s3 = boto3.client("s3", config=Config(signature_version="s3v4"))
    return _s3


def save(name: str, fileobj: BinaryIO) -> None:
    if BUCKET:
        content_type = mimetypes.guess_type(name)[0] or "application/octet-stream"
        _client().upload_fileobj(fileobj, BUCKET, PREFIX + name, ExtraArgs={"ContentType": content_type})
    else:
        with open(config.VIDEOS_DIR / name, "wb") as buffer:
            shutil.copyfileobj(fileobj, buffer)


def serve(name: str) -> Response:
    """The video from disk if it's there, otherwise a short-lived redirect to it in S3."""
    local = config.VIDEOS_DIR / name
    if local.is_file():
        return FileResponse(local)
    url = _client().generate_presigned_url(
        "get_object", Params={"Bucket": BUCKET, "Key": PREFIX + name}, ExpiresIn=URL_TTL_SECONDS
    )
    return RedirectResponse(url, status_code=302)
