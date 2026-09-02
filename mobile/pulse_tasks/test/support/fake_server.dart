// Кирпичики фейкового сервера для MockClient.
//
// Сам сервер у каждого теста свой — он держит ровно то состояние, которое тест
// проверяет. Общие здесь только две вещи: как из пути запроса достать имя ручки и
// как отдать JSON в той кодировке, в какой его отдаёт lsFusion.

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Имя ручки из пути запроса: `/exec/StoreTask.apiTasks` → `apiTasks`.
String actionOf(http.BaseRequest request) => request.url.path.split('.').last;

/// 200 с JSON-телом в UTF-8 и заголовком, как у сервера.
http.Response okJson(String body) => http.Response.bytes(utf8.encode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});
