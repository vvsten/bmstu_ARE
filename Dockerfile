FROM alt:p11

WORKDIR /app

COPY requirements.txt server.py model_loader.py ./

RUN apt-get update && apt-get install -y \
    build-essential \
    libsndfile libgomp ffmpeg \
    python3 python3-module-pip \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir -r requirements.txt

EXPOSE 8000

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000"]
