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
# Папка журнала хода генерации (CODEGEN_LOG_DIR): /srv принадлежит root, и сам сервис завести
# её не может. Volume из docker-compose.yml, смонтированный сюда, наследует её владельца.
RUN mkdir -p logs/codegen && chown -R aisvc:aisvc logs
USER aisvc

EXPOSE 8010

# 0.0.0.0 — адрес внутри контейнера, иначе проброс портов до процесса не доходит. Снаружи
# сервис виден там, где его публикует docker-compose.yml: по умолчанию на 127.0.0.1 хоста.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8010"]
