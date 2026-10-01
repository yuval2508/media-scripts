# Build from the repo root:  docker build -f web/Dockerfile -t subs-web .
FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg jq curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY *.sh scripts/

# Same venv layout the scripts expect (.venvs/whisper-subs next to them).
RUN python3 -m venv scripts/.venvs/whisper-subs \
    && scripts/.venvs/whisper-subs/bin/pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch \
    && scripts/.venvs/whisper-subs/bin/pip install --no-cache-dir faster-whisper transformers sentencepiece sacremoses

# ffsubsync in its own venv so its numpy pin can't clash with torch's.
RUN python3 -m venv /opt/ffsubsync \
    && /opt/ffsubsync/bin/pip install --no-cache-dir ffsubsync \
    && ln -s /opt/ffsubsync/bin/ffsubsync /usr/local/bin/ffsubsync

COPY web/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY web/app.py ./
COPY web/static static/

ENV SCRIPTS_DIR=/app/scripts DATA_DIR=/data HF_HOME=/cache HOME=/tmp
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
