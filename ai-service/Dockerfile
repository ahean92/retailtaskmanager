# Тонкий сервис: FastAPI и httpx, больше ничего. Ни модели, ни весов внутри —
# они живут в контейнере llm и в его volume, чтобы смена модели не требовала пересборки.
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1     PYTHONDONTWRITEBYTECODE=1

WORKDIR /srv

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Непривилегированный пользователь: сервис принимает запросы по сети, и root ему не
# нужен ни для чего.
RUN useradd --create-home --uid 10001 aisvc
USER aisvc

EXPOSE 8010

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8010"]
