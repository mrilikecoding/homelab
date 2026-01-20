FROM python:3.12-slim

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app

# Copy project files
COPY pyproject.toml .
COPY app.py .

# Install dependencies
RUN uv sync --no-dev

ENV PORT=5000
EXPOSE 5000

CMD ["uv", "run", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "5000"]
