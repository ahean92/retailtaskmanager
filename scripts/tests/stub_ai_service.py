"""Заглушка внешних сервисов для external_check.ps1: ai-service и выдача OAuth-токена Google.

Отвечает фиксированно, без модели и без сети, чтобы проверки сервера были детерминированы:
  POST /v1/hypothesis-code — код проверки гипотезы (как ai-service);
  POST /v1/task-draft      — черновик задачи по тексту (как ai-service);
       ключ доступа «Bearer zzz-bad» на /v1/* — 401, как у сервиса с другим ключом;
  POST /token              — access_token на час (как oauth2.googleapis.com/token);
  POST /token-bad          — 400 invalid_grant (Google отказал);
  GET  /health             — 200.
Запуск: python -I stub_ai_service.py <порт>; слушает только 127.0.0.1.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7711

SCRIPT = "run() { StoreTask.conclusion() <- 'ZZZ17 из генератора'; }"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length:
            self.rfile.read(length)
        auth = self.headers.get('Authorization') or ''
        if self.path.startswith('/v1/') and auth.endswith('zzz-bad'):
            return self._send(401, {'detail': 'invalid api key'})
        if self.path == '/v1/hypothesis-code':
            return self._send(200, {'script': SCRIPT, 'summary': 'ZZZ17 пересказ кода',
                                    'model': 'zzz-stub', 'turns': 1, 'costUsd': 0})
        if self.path == '/v1/task-draft':
            return self._send(200, {'outcome': 'ok', 'taskName': 'ZZZ17 проверить витрину',
                                    'typeId': 'issue', 'objectId': 'ZZZ-SITE'})
        if self.path == '/token':
            return self._send(200, {'access_token': 'zzz17-token', 'expires_in': 3600,
                                    'token_type': 'Bearer'})
        if self.path == '/token-bad':
            return self._send(400, {'error': 'invalid_grant',
                                    'error_description': 'ZZZ17 bad grant'})
        return self._send(404, {'error': 'notFound'})

    def do_GET(self):
        if self.path == '/health':
            return self._send(200, {'status': 'ok'})
        return self._send(404, {'error': 'notFound'})

    def log_message(self, *args):
        pass


if __name__ == '__main__':
    HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
